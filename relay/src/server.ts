import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { WebSocketServer, type WebSocket } from "ws";
import { Registry } from "./registry.js";
import { verifyAuth, idFromPublicKey, randomNonce } from "./auth.js";

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
  await new Promise<void>((r) => server.listen(opts.port, "127.0.0.1", r));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : opts.port;
  return { port, registry, close: () => new Promise((r) => { wss.close(); server.close(() => r()); }) };
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
          registry.registerHost(id, ws, allowed);
        } else {
          registry.registerClient(id, ws);
        }
        ws.send(JSON.stringify({ type: "authed", id }));
      } catch {
        ws.close(4001, "auth");
      }
    })();
  });

  ws.once("close", () => {
    if (!authedId) return;
    if (role === "host") registry.unregisterHost(authedId);
    else registry.unregisterClient(authedId);
  });
}

if (process.argv[1] && process.argv[1].endsWith("server.js")) {
  const port = Number(process.env.PORT ?? 8787);
  startRelay({ port, webRoot: new URL("../web", import.meta.url).pathname }).then((r) => console.log(`memterm relay on ${r.port}`));
}
