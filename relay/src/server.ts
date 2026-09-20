import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { WebSocketServer, type WebSocket } from "ws";
import { Registry } from "./registry.js";
import { verifyAuth, idFromPublicKey, randomNonce } from "./auth.js";
import { parseInbound, type EnvMessage } from "./envelope.js";

const PAIRING_TTL_MS = 120_000;

export interface RelayOptions { port: number; webRoot: string }
export interface RunningRelay { port: number; close(): Promise<void>; registry: Registry }

function b64(bytes: Uint8Array): string { return Buffer.from(bytes).toString("base64"); }
function fromB64(s: string): Uint8Array { return new Uint8Array(Buffer.from(s, "base64")); }

const MIME: Record<string, string> = { ".html": "text/html; charset=utf-8", ".js": "text/javascript", ".css": "text/css", ".json": "application/json" };

export async function startRelay(opts: RelayOptions): Promise<RunningRelay> {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://relay");
    if (url.pathname === "/healthz") { res.writeHead(200, { "content-type": "text/plain" }); res.end("ok"); return; }
    const rel = url.pathname === "/" ? "index.html" : url.pathname.replace(/^\/+/, "");
    const file = path.normalize(path.join(opts.webRoot, rel));
    if (!file.startsWith(path.normalize(opts.webRoot))) { res.writeHead(403); res.end(); return; }
    try {
      const body = await readFile(file);
      res.writeHead(200, { "content-type": MIME[path.extname(file)] ?? "application/octet-stream" });
      res.end(body);
    } catch { res.writeHead(404); res.end("not found"); }
  });
  const registry = new Registry();
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://relay");
    if (url.pathname !== "/host" && url.pathname !== "/client") { socket.destroy(); return; }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req, url.pathname));
  });
  wss.on("connection", (ws: WebSocket, req: http.IncomingMessage, pathname: string) => {
    handleConnection(ws, pathname === "/host" ? "host" : "client", registry);
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

function handleConnection(ws: WebSocket, role: "host" | "client", registry: Registry): void {
  const nonce = randomNonce();
  let authedId: string | undefined;
  ws.send(JSON.stringify({ type: "challenge", nonce: b64(nonce) }));

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
        if (role === "host") {
          const allowed = new Set<string>(Array.isArray(msg.allowed) ? msg.allowed : []);
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
        ws.on("message", (raw2: Buffer) => handlePeerMessage(raw2, role, id, ws, registry));
      } catch {
        ws.close(4001, "auth");
      }
    })();
  });

  ws.once("close", () => {
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
      const pairing = registry.consumePairing(msg.token, Date.now());
      const host = pairing ? registry.host(pairing.hostId) : undefined;
      if (!host) { ws.send(JSON.stringify({ type: "pair-denied", reason: "token" })); return; }
      host.socket.send(JSON.stringify({ type: "pair-request", deviceId: id, publicKey: msg.publicKey, name: msg.name }));
      return;
    }
    case "pair-answer": {
      if (role !== "host") return;
      const host = registry.host(id);
      const device = registry.client(msg.deviceId);
      if (!device) return;
      if (msg.accept) {
        host?.allowed.add(msg.deviceId);
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
      if (host) host.allowed = new Set(msg.devices);
      return;
    }
  }
}

function handleEnvelope(msg: EnvMessage, role: "host" | "client", senderId: string, registry: Registry): void {
  if (role === "client") {
    const sender = registry.client(senderId);
    const host = registry.host(msg.to);
    if (!host) { sender?.socket.send(JSON.stringify({ type: "refused", reason: "not-connected" })); return; }
    if (!host.allowed.has(senderId)) { sender?.socket.send(JSON.stringify({ type: "refused", reason: "not-allowed" })); return; }
    host.socket.send(JSON.stringify(msg));
  } else {
    const host = registry.host(senderId);
    const client = registry.client(msg.to);
    if (!client) { host?.socket.send(JSON.stringify({ type: "refused", reason: "not-connected" })); return; }
    if (!host?.allowed.has(msg.to)) { host?.socket.send(JSON.stringify({ type: "refused", reason: "not-allowed" })); return; }
    client.socket.send(JSON.stringify(msg));
  }
}

if (process.argv[1] && process.argv[1].endsWith("server.js")) {
  const port = Number(process.env.PORT ?? 8787);
  startRelay({ port, webRoot: new URL("../web", import.meta.url).pathname }).then((r) => console.log(`memterm relay on ${r.port}`));
}
