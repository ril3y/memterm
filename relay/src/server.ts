import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { WebSocketServer, type WebSocket } from "ws";
import { Registry, capSet, MAX_ALLOWED_DEVICES } from "./registry.js";
import { verifyAuth, idFromPublicKey, randomNonce } from "./auth.js";
import { parseInbound, type EnvMessage } from "./envelope.js";

const PAIRING_TTL_MS = 120_000;
/// Final-review Important 5: this is a public endpoint on a 512 MB
/// shared-cpu-1x Fly machine, so an unauthenticated socket must not be able
/// to sit forever, and a peer whose TCP connection died silently (the mini
/// asleep, a phone backgrounded) must eventually be noticed and its
/// watchers told `offline` rather than kept "online" against a socket
/// nobody is reading.
const DEFAULT_AUTH_DEADLINE_MS = 10_000;
const DEFAULT_PING_INTERVAL_MS = 30_000;
/// Security review H1: there was no connection limit of any kind, so one
/// machine could open sockets until the relay ran out of memory or file
/// descriptors. 32 is far above a real user (one host plus a handful of
/// browsers from one NAT) and far below what a flood needs.
const DEFAULT_MAX_CONNECTIONS_PER_IP = 32;

export interface RelayOptions {
  port: number;
  webRoot: string;
  /** A socket that hasn't completed the auth handshake within this many ms
   *  is terminated. Tests set this to tens of ms; production uses the
   *  default. */
  authDeadlineMs?: number;
  /** How often an authenticated peer is pinged; a peer that misses two
   *  consecutive pongs is terminated, which fires the normal close-handler
   *  cleanup (a host's watchers get `offline`). Tests set this to tens of
   *  ms; production uses the default. */
  pingIntervalMs?: number;
  /** How many simultaneous WebSocket connections one client IP may hold.
   *  Tests set this to 1 or 2; production uses the default. */
  maxConnectionsPerIp?: number;
}
export interface RunningRelay { port: number; close(): Promise<void>; registry: Registry }

function b64(bytes: Uint8Array): string { return Buffer.from(bytes).toString("base64"); }
function fromB64(s: string): Uint8Array { return new Uint8Array(Buffer.from(s, "base64")); }

const MIME: Record<string, string> = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };

/**
 * Sent with EVERY static response (security review M3). None of this
 * defends against a relay that is itself hostile -- it serves the client,
 * so it can ship whatever JavaScript it likes (C1) -- but it does keep a
 * content-injection bug on this origin from becoming full client
 * compromise, and it is the defence in depth C1 otherwise has none of.
 *
 * `style-src` keeps 'unsafe-inline' because `web/index.html` carries its
 * whole stylesheet in a `<style>` block. Scripts do NOT: the only script
 * is `<script type="module" src="./app.js">`, so `default-src 'self'`
 * covers them with no inline allowance at all. `connect-src` has to admit
 * `wss:`/`ws:` because the page's own WebSocket URL is built from
 * `location.host` and is ws: on a loopback relay.
 */
const SECURITY_HEADERS: Record<string, string> = {
  "content-security-policy":
    "default-src 'self'; connect-src 'self' wss: ws:; img-src 'self' data:; style-src 'self' 'unsafe-inline'",
  "x-content-type-options": "nosniff",
  "strict-transport-security": "max-age=31536000",
};

/**
 * The peer address a connection limit counts against. Fly terminates TLS
 * and proxies, so `socket.remoteAddress` is the proxy for every real user;
 * `fly-client-ip` is the header it sets to the actual client. Taking the
 * header only when it is present means a self-hosted relay with no proxy
 * still counts real addresses.
 *
 * A header can be forged by anyone talking directly to the relay, which
 * only lets an attacker spread their own connections across made-up
 * buckets -- the same thing renting more IPs buys them. It is a memory
 * bound, not an authentication decision.
 */
function clientIp(req: http.IncomingMessage): string {
  const header = req.headers["fly-client-ip"];
  const value = Array.isArray(header) ? header[0] : header;
  if (typeof value === "string" && value.length > 0 && value.length <= 64) return value;
  return req.socket.remoteAddress ?? "unknown";
}

export async function startRelay(opts: RelayOptions): Promise<RunningRelay> {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://relay");
    if (url.pathname === "/healthz") { res.writeHead(200, { ...SECURITY_HEADERS, "content-type": "text/plain" }); res.end("ok"); return; }
    const rel = url.pathname === "/" ? "index.html" : url.pathname.replace(/^\/+/, "");
    const file = path.normalize(path.join(opts.webRoot, rel));
    if (!file.startsWith(path.normalize(opts.webRoot))) { res.writeHead(403, SECURITY_HEADERS); res.end(); return; }
    try {
      const body = await readFile(file);
      res.writeHead(200, { ...SECURITY_HEADERS, "content-type": MIME[path.extname(file)] ?? "application/octet-stream" });
      res.end(body);
    } catch { res.writeHead(404, SECURITY_HEADERS); res.end("not found"); }
  });
  const registry = new Registry();
  const authDeadlineMs = opts.authDeadlineMs ?? DEFAULT_AUTH_DEADLINE_MS;
  const pingIntervalMs = opts.pingIntervalMs ?? DEFAULT_PING_INTERVAL_MS;
  const maxConnectionsPerIp = opts.maxConnectionsPerIp ?? DEFAULT_MAX_CONNECTIONS_PER_IP;
  const connectionsPerIp = new Map<string, number>();
  // 1 MiB: generous for any real envelope (a terminal frame, a tree), and
  // small enough that a single unauthenticated peer can't buffer its way
  // to the `ws` default of 100 MiB on a 512 MB machine.
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1 << 20 });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://relay");
    if (url.pathname !== "/host" && url.pathname !== "/client") { socket.destroy(); return; }
    // Counted before the handshake completes, and released on close, so a
    // flood is refused at the door rather than after it has already cost a
    // WebSocket's worth of buffers (security review H1).
    const ip = clientIp(req);
    const open = connectionsPerIp.get(ip) ?? 0;
    if (open >= maxConnectionsPerIp) { socket.destroy(); return; }
    connectionsPerIp.set(ip, open + 1);
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      const now = connectionsPerIp.get(ip) ?? 1;
      if (now <= 1) connectionsPerIp.delete(ip); else connectionsPerIp.set(ip, now - 1);
    };
    // An upgrade that never becomes a WebSocket (the client hangs up mid
    // handshake) must not leak its slot either.
    socket.once("close", release);
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.once("close", release);
      wss.emit("connection", ws, req, url.pathname);
    });
  });
  wss.on("connection", (ws: WebSocket, req: http.IncomingMessage, pathname: string) => {
    handleConnection(ws, pathname === "/host" ? "host" : "client", registry, authDeadlineMs, pingIntervalMs);
  });
  await new Promise<void>((r) => server.listen(opts.port, process.env.HOST ?? "127.0.0.1", r));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : opts.port;
  return {
    port,
    registry,
    close: () =>
      new Promise((r) => {
        // wss.close() alone only stops accepting new upgrades; it leaves any
        // already-open sockets connected, which would keep server.close()'s
        // callback from ever firing.
        for (const client of wss.clients) client.terminate();
        wss.close();
        server.close(() => r());
      }),
  };
}

function handleConnection(
  ws: WebSocket,
  role: "host" | "client",
  registry: Registry,
  authDeadlineMs: number,
  pingIntervalMs: number
): void {
  const nonce = randomNonce();
  let authedId: string | undefined;
  // A protocol-level error (a frame over maxPayload, a malformed frame) is
  // an `error` event on the socket; `ws` already closes the connection with
  // the appropriate code on its own (1009 for maxPayload) — the listener's
  // only job is to exist, since Node re-throws an `error` event with no
  // listener as an uncaught exception, which is what turns "the socket
  // closes" into "the whole relay process crashes" the moment maxPayload is
  // enforced against a hostile peer.
  ws.on("error", () => {});
  ws.send(JSON.stringify({ type: "challenge", nonce: b64(nonce) }));

  // A socket that never answers the challenge (or never connects at all
  // past the TCP handshake) would otherwise sit here forever — the relay
  // sent a challenge and is waiting, with nothing else timing it out.
  const authDeadline = setTimeout(() => {
    if (!authedId) ws.terminate();
  }, authDeadlineMs);
  let stopHeartbeat: (() => void) | undefined;

  ws.once("message", (raw: Buffer) => {
    void (async () => {
      try {
        const msg = JSON.parse(raw.toString());
        if (msg?.type !== "auth" || typeof msg.publicKey !== "string" || typeof msg.signature !== "string") {
          ws.close(4001, "auth");
          return;
        }
        const spki = fromB64(msg.publicKey);
        const signature = fromB64(msg.signature);
        const ok = await verifyAuth(spki, nonce, signature);
        if (!ok) { ws.close(4001, "auth"); return; }
        const id = await idFromPublicKey(spki);
        authedId = id;
        clearTimeout(authDeadline);
        if (role === "host") {
          // Capped: a host is authenticated, not trusted with the relay's
          // memory (security review H1).
          const announced = Array.isArray(msg.allowed) ? msg.allowed.filter((d: unknown) => typeof d === "string") : [];
          const allowed = capSet(new Set<string>(announced.slice(0, MAX_ALLOWED_DEVICES)));
          registry.registerHost(id, ws, allowed, msg.publicKey);
          registry.markSeen(id, Date.now());
          ws.send(JSON.stringify({ type: "authed", id }));
          for (const client of registry.clientsAllowedBy(id)) {
            client.socket.send(JSON.stringify({ type: "online", hostId: id }));
          }
        } else {
          registry.registerClient(id, ws);
          ws.send(JSON.stringify({ type: "authed", id }));
        }
        stopHeartbeat = startHeartbeat(ws, pingIntervalMs);
        ws.on("message", (raw2: Buffer) => handlePeerMessage(raw2, role, id, ws, registry));
      } catch {
        ws.close(4001, "auth");
      }
    })();
  });

  ws.once("close", () => {
    clearTimeout(authDeadline);
    stopHeartbeat?.();
    if (!authedId) return;
    if (role === "host") {
      const lastSeen = registry.lastSeen(authedId) ?? Date.now();
      const allowedClients = registry.clientsAllowedBy(authedId);
      registry.unregisterHost(authedId);
      for (const client of allowedClients) {
        client.socket.send(JSON.stringify({ type: "offline", hostId: authedId, lastSeen }));
      }
    } else {
      registry.unregisterClient(authedId);
    }
  });
}

/**
 * Standard `ws` heartbeat: pings every `pingIntervalMs` and expects a pong
 * before the NEXT ping goes out. Two consecutive unanswered pings (the
 * connection has been silent for roughly two full intervals) terminate the
 * socket, which fires the normal `close` handler above — a dead host's
 * watchers get `offline` instead of the relay holding it "online" against a
 * TCP connection nobody is reading (the mini asleep, a phone backgrounded).
 * Returns a function that stops the heartbeat (called on `close`).
 */
function startHeartbeat(ws: WebSocket, pingIntervalMs: number): () => void {
  let unanswered = 0;
  const onPong = () => { unanswered = 0; };
  ws.on("pong", onPong);
  const timer = setInterval(() => {
    if (unanswered >= 2) {
      clearInterval(timer);
      ws.terminate();
      return;
    }
    unanswered++;
    try { ws.ping(); } catch { /* socket already closing */ }
  }, pingIntervalMs);
  return () => {
    clearInterval(timer);
    ws.off("pong", onPong);
  };
}

function handlePeerMessage(raw: Buffer, role: "host" | "client", id: string, ws: WebSocket, registry: Registry): void {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.toString());
  } catch {
    ws.close(4002, "type");
    return;
  }
  const msg = parseInbound(parsed);
  if (!msg) {
    ws.close(4002, "type");
    return;
  }

  if (role === "host") registry.markSeen(id, Date.now());

  switch (msg.type) {
    case "env":
      if (msg.from !== id) { ws.close(4003, "from"); return; }
      handleEnvelope(msg, role, id, registry);
      return;
    case "pair-token":
      if (role !== "host") return;
      registry.createPairing(id, msg.token, PAIRING_TTL_MS, Date.now());
      return;
    case "pair": {
      if (role !== "client") return;
      // The key in a pair request must be the key this socket authenticated
      // with (security review C2). Without that, a client could present
      // somebody else's public key -- or a hostile relay operator's -- and
      // the host would be asked to trust a key whose owner never consumed
      // the token. `id` was derived from the SPKI that signed the auth
      // challenge, so comparing ids compares keys.
      void (async () => {
        let claimedId: string;
        try {
          claimedId = await idFromPublicKey(fromB64(msg.publicKey));
        } catch {
          ws.close(4004, "key");
          return;
        }
        if (claimedId !== id) { ws.close(4004, "key"); return; }
        const pairing = registry.consumePairing(msg.token, Date.now());
        const host = pairing ? registry.host(pairing.hostId) : undefined;
        if (!host) { ws.send(JSON.stringify({ type: "pair-denied", reason: "token" })); return; }
        // `proof` travels opaque: only the host holds the secret half of
        // the token, so only the host can check it.
        host.socket.send(JSON.stringify({
          type: "pair-request", deviceId: id, publicKey: msg.publicKey, name: msg.name, proof: msg.proof,
        }));
      })();
      return;
    }
    case "pair-answer": {
      if (role !== "host") return;
      const host = registry.host(id);
      const device = registry.client(msg.deviceId);
      if (!device) return;
      if (msg.accept) {
        if (host && host.allowed.size < MAX_ALLOWED_DEVICES) host.allowed.add(msg.deviceId);
        registry.addWatcher(id, msg.deviceId);
        device.socket.send(JSON.stringify({ type: "paired", hostId: id, hostPublicKey: host?.publicKey ?? "" }));
      } else {
        device.socket.send(JSON.stringify({ type: "pair-denied", reason: "host" }));
      }
      return;
    }
    case "allowed": {
      if (role !== "host") return;
      const host = registry.host(id);
      if (host) host.allowed = capSet(new Set(msg.devices.slice(0, MAX_ALLOWED_DEVICES)));
      return;
    }
  }
}

/**
 * One refusal reason for both "that peer is not connected" and "that peer
 * never allowed you" (security review L2). Two distinct reasons made the
 * relay a host-existence oracle: an 80-bit id space makes that useless in
 * practice, but there is no reason to answer the question at all.
 */
const REFUSED = JSON.stringify({ type: "refused", reason: "not-allowed" });

function handleEnvelope(msg: EnvMessage, role: "host" | "client", senderId: string, registry: Registry): void {
  if (role === "client") {
    const sender = registry.client(senderId);
    const host = registry.host(msg.to);
    if (!host || !host.allowed.has(senderId)) { sender?.socket.send(REFUSED); return; }
    host.socket.send(JSON.stringify(msg));
  } else {
    const host = registry.host(senderId);
    const client = registry.client(msg.to);
    if (!client || !host?.allowed.has(msg.to)) { host?.socket.send(REFUSED); return; }
    client.socket.send(JSON.stringify(msg));
  }
}

if (process.argv[1] && process.argv[1].endsWith("server.js")) {
  const port = Number(process.env.PORT ?? 8787);
  startRelay({ port, webRoot: new URL("../web", import.meta.url).pathname }).then((r) => console.log(`memterm relay on ${r.port}`));
}
