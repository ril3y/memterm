import http from "node:http";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { WebSocketServer } from "ws";

export interface RelayOptions { port: number; webRoot: string }
export interface RunningRelay { port: number; close(): Promise<void> }

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
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    const url = new URL(req.url ?? "/", "http://relay");
    if (url.pathname !== "/host" && url.pathname !== "/client") { socket.destroy(); return; }
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
  });
  await new Promise<void>((r) => server.listen(opts.port, "127.0.0.1", r));
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : opts.port;
  return { port, close: () => new Promise((r) => { wss.close(); server.close(() => r()); }) };
}

if (process.argv[1] && process.argv[1].endsWith("server.js")) {
  const port = Number(process.env.PORT ?? 8787);
  startRelay({ port, webRoot: new URL("../web", import.meta.url).pathname }).then((r) => console.log(`memterm relay on ${r.port}`));
}
