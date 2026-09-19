# Remote Attach Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror and control the terminal sessions running inside memterm on the Mac mini from a phone browser or another computer, through a blind (end-to-end encrypted) relay on Fly.

**Architecture:** Three units. A **relay** (Node 20 + `ws`, one Fly machine) that authenticates hosts and devices by key, pairs them, and forwards opaque envelopes. A **remote host** inside memterm that keeps an outbound WebSocket to the relay, exposes the live workspace tree, and streams a pane's raw pty bytes to attached viewers. A **web client** (TypeScript + xterm.js) served by the relay. All crypto is P-256 ECDH + HKDF-SHA256 + AES-256-GCM — CryptoKit on the Mac, WebCrypto in the browser and in Node — with shared test vectors so the two stacks are proven to agree.

**Tech Stack:** Swift 6 / CryptoKit / URLSessionWebSocketTask (host); Node 20 + TypeScript + `ws` + `node:test` (relay); TypeScript + xterm.js + esbuild (web); the existing UI probe harness (end-to-end).

**Spec:** `docs/superpowers/specs/2026-09-19-remote-attach-design.md`

## Global Constraints

- Remote access is **off by default**; nothing connects anywhere until Settings ▸ Remote is switched on.
- The relay **never decrypts**: it sees `{to, from, payload}` envelopes and ID headers only; it persists nothing.
- The host is the **running memterm app**; no daemon, no launch agent.
- A remote client can do **only what a local keyboard can do** to a pane (bytes into the pty). No side channel.
- Crypto: **P-256** identity + ephemeral keys, **HKDF-SHA256** with info `"memterm-remote-v1" ‖ hostId ‖ deviceId`, **AES-256-GCM**, 96-bit per-direction counter nonces. Host ID = base32(SHA-256(hostPublicKey))[0..<16], lower case, no padding.
- Per-viewer output backlog cap **256 KB**, oldest dropped. Pairing token: single-use, **2-minute** expiry. Unlock rate limit: **5 per minute per device**.
- MemtermCore stays AppKit-free (CryptoKit and Foundation are fine). New Swift files go under `Sources/MemtermCore/Remote/` and `Sources/memterm/Remote/`.
- House testing style: pure seams in `Tests/MemtermCoreTests`, `node:test` for the relay and web codec, one UI probe leg for the end-to-end path, `verify.sh` greps every measured line.
- Commit after every task with the session's attribution trailer.

---

## File Structure

```
relay/                                  (new; its own package.json, tsconfig, Dockerfile, fly.toml)
  src/server.ts                          HTTP + WebSocket server; routes /host, /client, /healthz, static /
  src/registry.ts                        in-memory hosts / devices / pairings; pure, tested
  src/auth.ts                            nonce challenge + ECDSA P-256 verify (WebCrypto)
  src/envelope.ts                        envelope schema + validation
  test/*.test.ts                         node:test suites
  web/index.html, web/src/app.ts,        the web client
  web/src/crypto.ts, web/src/codec.ts
  web/test/vectors.test.ts               shared crypto/codec vectors
Sources/MemtermCore/Remote/
  RemoteMessage.swift                    inner protocol (Codable enum) + JSON codec
  RemoteEnvelope.swift                   outer envelope
  RemoteCrypto.swift                     identity keys, handshake, session keys, sealed records
  RemoteTree.swift                       workspace/window/tab/pane tree model + serialization
  OutputBacklog.swift                    per-viewer bounded byte queue
  UnlockRateLimiter.swift                5/min per device
Tests/MemtermCoreTests/Remote*Tests.swift
Tests/vectors/remote-crypto-vectors.json (generated once by Task 6; consumed by Task 10)
Sources/memterm/Remote/
  RemoteHost.swift                       relay socket, auth, pairing, sessions, dispatch
  RemotePaneStream.swift                 pane tap → viewers; input → pty; screen snapshot
  RemoteDeviceStore.swift                paired devices + host identity (Keychain + JSON file)
  RemoteSettingsSection.swift            Settings ▸ Remote UI (switch, URL, QR, device list)
Sources/memterm/PaneView.swift           add outputTaps + visibleScreenBytes()
Sources/memterm/ProbeLegs.swift          remote end-to-end leg
scripts/verify.sh                        new checks
.github/workflows/ci.yml, release.yml    relay tests; fly deploy
```

---

### Task 1: Relay skeleton — HTTP server, `/healthz`, static web root, `node:test` harness

**Files:**
- Create: `relay/package.json`, `relay/tsconfig.json`, `relay/src/server.ts`, `relay/test/server.test.ts`, `relay/web/index.html` (placeholder)

**Interfaces:**
- Produces: `startRelay(opts: {port: number, webRoot: string}): Promise<{port: number, close(): Promise<void>}>` exported from `src/server.ts`.

- [ ] **Step 1: Scaffold the package**

`relay/package.json`:
```json
{
  "name": "memterm-relay",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": {
    "build": "tsc",
    "start": "node dist/server.js",
    "test": "tsc && node --test dist/test/",
    "web": "esbuild web/src/app.ts --bundle --outfile=web/dist/app.js --format=esm"
  },
  "dependencies": { "ws": "^8.21.3" },
  "devDependencies": { "typescript": "^5.6.0", "@types/node": "^20.14.0", "@types/ws": "^8.5.12", "esbuild": "^0.24.0", "@xterm/xterm": "^5.5.0", "@xterm/addon-fit": "^0.10.0" }
}
```
`relay/tsconfig.json`:
```json
{ "compilerOptions": { "target": "ES2022", "module": "NodeNext", "moduleResolution": "NodeNext", "strict": true, "outDir": "dist", "rootDir": ".", "lib": ["ES2022", "DOM"], "types": ["node"] }, "include": ["src", "test", "web/src"] }
```

- [ ] **Step 2: Write the failing test**

`relay/test/server.test.ts`:
```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { startRelay } from "../src/server.js";

test("healthz answers ok and the web root is served", async () => {
  const relay = await startRelay({ port: 0, webRoot: new URL("../web", import.meta.url).pathname });
  const health = await fetch(`http://127.0.0.1:${relay.port}/healthz`);
  assert.equal(health.status, 200);
  assert.equal(await health.text(), "ok");
  const index = await fetch(`http://127.0.0.1:${relay.port}/`);
  assert.equal(index.status, 200);
  assert.match(await index.text(), /memterm/);
  await relay.close();
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd relay && npm install && npm test`
Expected: FAIL — cannot find module `../src/server.js`.

- [ ] **Step 4: Minimal server**

`relay/src/server.ts`:
```ts
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
```
`relay/web/index.html`: `<!doctype html><title>memterm</title><h1>memterm remote</h1>`

Note: the production listener must bind `0.0.0.0` on Fly — Task 4 adds `host: process.env.HOST ?? "127.0.0.1"`.

- [ ] **Step 5: Run the test to verify it passes** — `npm test` → PASS.

- [ ] **Step 6: Commit**
```bash
git add relay && git commit -m "relay: skeleton server with /healthz and static web root (node:test harness)"
```

---

### Task 2: Relay registry + authentication (nonce challenge, ECDSA P-256)

**Files:**
- Create: `relay/src/registry.ts`, `relay/src/auth.ts`, `relay/test/registry.test.ts`, `relay/test/auth.test.ts`
- Modify: `relay/src/server.ts` (wire `/host` and `/client` to auth)

**Interfaces:**
- Produces (registry): `class Registry { registerHost(hostId, socket, allowed: Set<string>): void; unregisterHost(hostId): void; host(hostId): HostEntry|undefined; registerClient(deviceId, socket): void; unregisterClient(deviceId): void; client(deviceId): ClientEntry|undefined; createPairing(hostId, token, ttlMs, now): void; consumePairing(token, now): {hostId}|undefined }`. `HostEntry = {socket, allowed: Set<string>}`.
- Produces (auth): `verifyAuth(pub: JsonWebKey, nonce: Uint8Array, signature: Uint8Array): Promise<boolean>`; `idFromPublicKey(rawSpki: Uint8Array): Promise<string>` = base32(sha256)[0..16] lower-case; `randomNonce(): Uint8Array` (32 bytes).
- Wire protocol on `/host` and `/client`: server sends `{"type":"challenge","nonce":<b64>}`; peer replies `{"type":"auth","publicKey":<b64 SPKI>,"signature":<b64 ECDSA-P256-SHA256 over nonce>, "allowed":[deviceIdHash…]}` (allowed: host only); server replies `{"type":"authed","id":<computed id>}` or closes with code 4001.

- [ ] **Step 1: Registry test**

`relay/test/registry.test.ts`:
```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { Registry } from "../src/registry.js";

const sock = () => ({ send() {}, close() {} }) as any;

test("pairing tokens are single-use and expire", () => {
  const r = new Registry();
  r.createPairing("h1", "tok", 120_000, 1_000);
  assert.equal(r.consumePairing("tok", 60_000)?.hostId, "h1");
  assert.equal(r.consumePairing("tok", 60_000), undefined);        // single use
  r.createPairing("h1", "tok2", 120_000, 1_000);
  assert.equal(r.consumePairing("tok2", 200_000), undefined);      // expired
});

test("hosts carry an allow-list; clients are looked up by device id", () => {
  const r = new Registry();
  r.registerHost("h1", sock(), new Set(["dA"]));
  r.registerClient("dA", sock());
  assert.ok(r.host("h1")!.allowed.has("dA"));
  assert.ok(r.client("dA"));
  r.unregisterHost("h1");
  assert.equal(r.host("h1"), undefined);
});
```

- [ ] **Step 2: Auth test (real WebCrypto keys)**

`relay/test/auth.test.ts`:
```ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { verifyAuth, idFromPublicKey, randomNonce } from "../src/auth.js";

test("a signature over the nonce by the key's owner verifies; a tampered one does not", async () => {
  const kp = await webcrypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = new Uint8Array(await webcrypto.subtle.exportKey("spki", kp.publicKey));
  const nonce = randomNonce();
  const sig = new Uint8Array(await webcrypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, kp.privateKey, nonce));
  assert.equal(await verifyAuth(spki, nonce, sig), true);
  nonce[0] ^= 1;
  assert.equal(await verifyAuth(spki, nonce, sig), false);
  const id = await idFromPublicKey(spki);
  assert.match(id, /^[a-z2-7]{16}$/);
});
```

- [ ] **Step 3: Run both → FAIL (modules missing)**

- [ ] **Step 4: Implement**

`relay/src/registry.ts`:
```ts
export interface PeerSocket { send(data: string): void; close(code?: number, reason?: string): void }
export interface HostEntry { socket: PeerSocket; allowed: Set<string> }
export interface ClientEntry { socket: PeerSocket }

export class Registry {
  private hosts = new Map<string, HostEntry>();
  private clients = new Map<string, ClientEntry>();
  private pairings = new Map<string, { hostId: string; expiresAt: number }>();
  registerHost(hostId: string, socket: PeerSocket, allowed: Set<string>) { this.hosts.set(hostId, { socket, allowed }); }
  unregisterHost(hostId: string) { this.hosts.delete(hostId); }
  host(hostId: string) { return this.hosts.get(hostId); }
  registerClient(deviceId: string, socket: PeerSocket) { this.clients.set(deviceId, { socket }); }
  unregisterClient(deviceId: string) { this.clients.delete(deviceId); }
  client(deviceId: string) { return this.clients.get(deviceId); }
  createPairing(hostId: string, token: string, ttlMs: number, now: number) { this.pairings.set(token, { hostId, expiresAt: now + ttlMs }); }
  consumePairing(token: string, now: number) {
    const p = this.pairings.get(token); if (!p) return undefined;
    this.pairings.delete(token);
    return now <= p.expiresAt ? { hostId: p.hostId } : undefined;
  }
}
```
`relay/src/auth.ts`:
```ts
import { webcrypto, createHash } from "node:crypto";
const ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";
export function base32(bytes: Uint8Array): string {
  let bits = 0, value = 0, out = "";
  for (const b of bytes) { value = (value << 8) | b; bits += 8; while (bits >= 5) { out += ALPHABET[(value >>> (bits - 5)) & 31]; bits -= 5; } }
  if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 31];
  return out;
}
export async function idFromPublicKey(spki: Uint8Array): Promise<string> {
  return base32(createHash("sha256").update(spki).digest()).slice(0, 16);
}
export function randomNonce(): Uint8Array { return webcrypto.getRandomValues(new Uint8Array(32)); }
export async function verifyAuth(spki: Uint8Array, nonce: Uint8Array, signature: Uint8Array): Promise<boolean> {
  try {
    const key = await webcrypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await webcrypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, signature, nonce);
  } catch { return false; }
}
```
Wire into `server.ts` `wss.on("connection", (ws, req))`: send the challenge; on the first message parse `auth`, verify, compute the id, `registry.registerHost(id, ws, new Set(msg.allowed ?? []))` or `registerClient(id, ws)`, reply `authed`; anything else → `ws.close(4001, "auth")`. On `close` unregister. Export `registry` on the `RunningRelay` for tests.

- [ ] **Step 5: Run → PASS. Step 6: Commit** `git commit -m "relay: registry + nonce/ECDSA authentication for hosts and clients"`

---

### Task 3: Relay pairing, forwarding, presence, revocation

**Files:**
- Create: `relay/src/envelope.ts`, `relay/test/forwarding.test.ts`
- Modify: `relay/src/server.ts`

**Interfaces:**
- Envelope (both directions): `{"type":"env","to":<id>,"from":<id>,"payload":<b64>}`; the relay checks `from === socket's authed id` and that the pair is allowed (`host.allowed.has(deviceId)`), then forwards verbatim.
- Pairing: host → relay `{"type":"pair-token","token":<string>}` (registers, 120 s TTL). Client → relay `{"type":"pair","token":<string>,"publicKey":<b64 SPKI>,"name":<string>}`. Relay → host `{"type":"pair-request","deviceId":<id>,"publicKey":<b64>,"name":<string>}`. Host → relay `{"type":"pair-answer","deviceId":<id>,"accept":true|false}`; on accept the relay adds `deviceId` to `allowed` and tells the client `{"type":"paired","hostId":<id>,"hostPublicKey":<b64>}`, else `{"type":"pair-denied"}`.
- Presence: when a host socket closes, every allowed client gets `{"type":"offline","hostId":<id>,"lastSeen":<ms>}`; when it (re)registers, `{"type":"online","hostId":<id>}`.
- Host → relay `{"type":"allowed","devices":[…]}` replaces the allow-list at any time (revocation).

- [ ] **Step 1: Failing test (drives two fake authed peers through the real server)**

`relay/test/forwarding.test.ts` — helper `connectAuthed(port, path, extra)` generates a WebCrypto key pair, opens `ws://127.0.0.1:port/path`, answers the challenge, returns `{ws, id, spki}`. Tests:
```ts
test("pairing, forwarding both ways, host-drop → offline, revocation", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  const host = await connectAuthed(relay.port, "host", { allowed: [] });
  host.ws.send(JSON.stringify({ type: "pair-token", token: "T1" }));
  const dev = await connectAuthed(relay.port, "client", {});
  dev.ws.send(JSON.stringify({ type: "pair", token: "T1", publicKey: b64(dev.spki), name: "phone" }));
  const req = await next(host.ws, "pair-request");
  assert.equal(req.deviceId, dev.id);
  host.ws.send(JSON.stringify({ type: "pair-answer", deviceId: dev.id, accept: true }));
  const paired = await next(dev.ws, "paired");
  assert.equal(paired.hostId, host.id);
  dev.ws.send(JSON.stringify({ type: "env", to: host.id, from: dev.id, payload: "AQID" }));
  assert.equal((await next(host.ws, "env")).payload, "AQID");
  host.ws.send(JSON.stringify({ type: "env", to: dev.id, from: host.id, payload: "BAUG" }));
  assert.equal((await next(dev.ws, "env")).payload, "BAUG");
  host.ws.send(JSON.stringify({ type: "allowed", devices: [] }));          // revoke
  dev.ws.send(JSON.stringify({ type: "env", to: host.id, from: dev.id, payload: "AQID" }));
  assert.equal((await next(dev.ws, "refused")).reason, "not-allowed");
  host.ws.close();
  assert.equal((await next(dev.ws, "offline")).hostId, host.id);
  await relay.close();
});
test("a forged from is dropped and the socket closed", …);   // send env with from = someone else → close code 4003
test("an expired or reused pairing token is denied", …);
```

- [ ] **Step 2: Run → FAIL. Step 3: Implement** `envelope.ts` (type guards for each message shape; reject unknown types), the message switch in `server.ts` per the interface above, `lastSeen` tracked per host in the registry (`markSeen(hostId, now)`), and `offline` fan-out on host close (iterate `registry.clientsAllowedBy(hostId)` — add that query to the registry).

- [ ] **Step 4: Run → PASS. Step 5: Commit** `git commit -m "relay: pairing, envelope forwarding, presence, revocation"`

---

### Task 4: Relay container, Fly config, CI job

**Files:**
- Create: `relay/Dockerfile`, `relay/fly.toml`, `relay/.dockerignore`
- Modify: `relay/src/server.ts` (bind `HOST`), `.github/workflows/ci.yml` (relay job), `README.md` (relay section)

- [ ] **Step 1: Dockerfile** (mirrors `SmartFoodie/smartfoodie-api/Dockerfile` — multi-stage, `node:20-alpine`, `npm ci`, `npm run build && npm run web`, `CMD ["node","dist/src/server.js"]`, `EXPOSE 8787`).
- [ ] **Step 2: fly.toml**
```toml
app = 'memterm-relay'
primary_region = 'iad'
[build]
  dockerfile = 'Dockerfile'
[env]
  PORT = '8787'
  HOST = '0.0.0.0'
[http_service]
  internal_port = 8787
  force_https = true
  auto_stop_machines = 'off'
  auto_start_machines = true
  min_machines_running = 1
[[vm]]
  size = 'shared-cpu-1x'
  memory = '512mb'
```
- [ ] **Step 3: `server.ts` listens on `process.env.HOST ?? "127.0.0.1"`.** Test from Task 1 still passes (it uses 127.0.0.1).
- [ ] **Step 4: CI job** in `ci.yml`: `relay-tests` on `ubuntu-latest`: `actions/setup-node@v4` (node 20), `npm ci`, `npm test`, working-directory `relay`.
- [ ] **Step 5: Build the image locally once** (`docker build relay`) if Docker is available; otherwise rely on CI. **Step 6: Commit** `git commit -m "relay: Dockerfile, fly.toml, CI job"`

---

### Task 5: MemtermCore — inner protocol and envelope codecs

**Files:**
- Create: `Sources/MemtermCore/Remote/RemoteMessage.swift`, `Sources/MemtermCore/Remote/RemoteEnvelope.swift`, `Tests/MemtermCoreTests/RemoteMessageTests.swift`

**Interfaces:**
- Produces:
```swift
public enum RemoteMessage: Equatable {
    case list
    case attach(paneId: String)
    case detach
    case input(Data)
    case resize(cols: Int, rows: Int)
    case newTab(workspaceId: String)
    case unlock(workspaceId: String, passphrase: String)
    case tree(RemoteTree)
    case screen(cols: Int, rows: Int, bytes: Data)
    case output(Data)
    case treeChanged
    case refused(reason: String)
    case resized(cols: Int, rows: Int)
    public func encode() -> Data          // one JSON object: {"t":"attach","paneId":…} ; bytes as base64 "b"
    public static func decode(_ data: Data) -> RemoteMessage?
}
public struct RemoteEnvelope: Equatable { public var to: String; public var from: String; public var payload: Data;
    public func encode() -> Data /* {"type":"env",…} */; public static func decode(_ data: Data) -> RemoteEnvelope? }
```
The JSON tags (`"t"` values) are exactly: `list attach detach input resize newTab unlock tree screen output tree-changed refused resized`. Byte fields are base64 under key `"b"`.

- [ ] **Step 1: Failing tests** — round-trip every case; `decode` of `{"t":"bogus"}` returns nil; `input` bytes survive base64; `RemoteEnvelope` round-trips and rejects a missing `to`.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** (a small hand-written `Codable` on a private `Wire` struct with optional fields; `RemoteTree` from Task 7 — stub it here as `public struct RemoteTree: Codable, Equatable { public var workspaces: [RemoteWorkspace] }` with the fields the spec lists, so Task 7 only adds the builder).
- [ ] **Step 4: Run → PASS. Step 5: Commit** `git commit -m "core: remote inner protocol + envelope codecs"`

---

### Task 6: MemtermCore — crypto (identity, handshake, sealed records) with shared vectors

**Files:**
- Create: `Sources/MemtermCore/Remote/RemoteCrypto.swift`, `Tests/MemtermCoreTests/RemoteCryptoTests.swift`, `Tests/vectors/remote-crypto-vectors.json`
- Modify: `Package.swift` (add `resources: [.copy("../vectors")]` is awkward — instead the test locates the file relative to `#filePath`).

**Interfaces:**
- Produces:
```swift
public struct RemoteIdentity {               // long-lived
    public let privateKey: P256.Signing.PrivateKey
    public var publicKeySPKI: Data           // DER SubjectPublicKeyInfo (x963 → SPKI wrap), what the relay + peers see
    public var id: String                     // base32(sha256(spki))[0..<16]
    public static func generate() -> RemoteIdentity
    public init(privateKeyRaw: Data) throws
    public func sign(_ data: Data) -> Data   // ECDSA P-256 SHA-256, DER signature converted to raw r‖s (64 bytes) — WebCrypto's format
}
public struct RemoteHandshake {
    /// Both sides: fresh ephemeral key, signed by the identity so the peer knows who it is talking to.
    public struct Hello: Equatable { public var ephemeralRaw: Data /* x963 65 bytes */; public var signature: Data }
    public static func makeHello(identity: RemoteIdentity) -> (Hello, P256.KeyAgreement.PrivateKey)
    public static func verifyHello(_ hello: Hello, peerSPKI: Data) -> Bool
    public static func deriveKeys(myEphemeral: P256.KeyAgreement.PrivateKey, peerEphemeralRaw: Data, hostId: String, deviceId: String, iAmHost: Bool) throws -> RemoteSessionKeys
}
public final class RemoteSessionKeys {
    public func seal(_ plaintext: Data) throws -> Data        // nonce = 96-bit big-endian counter (send), record = nonce ‖ ciphertext ‖ tag
    public func open(_ record: Data) throws -> Data           // verifies the counter is exactly the next expected; otherwise throws RemoteCryptoError.replay
}
public enum RemoteCryptoError: Error { case badSignature, replay, malformed }
```
Key schedule (must match the web client byte-for-byte): `okm = HKDF-SHA256(ikm: ECDH shared secret (x963 x-coordinate 32 bytes), salt: empty, info: "memterm-remote-v1" ‖ hostId ‖ deviceId (UTF-8, no separators), length: 64)`; host→client key = okm[0..<32], client→host key = okm[32..<64]. Nonce: 12 bytes, big-endian counter starting at 0, per direction.

- [ ] **Step 1: Failing tests** — (a) identity round trip + `id` format; (b) `sign`/verify via `P256.Signing.PublicKey(x963:)`; (c) two parties handshake and `seal`/`open` both directions; (d) a replayed record throws `.replay`; (e) **vectors**: with a fixed shared secret, hostId, deviceId, key 0 seals plaintext `"hello"` with counter 0 → assert against `Tests/vectors/remote-crypto-vectors.json` (`{"sharedSecretHex","hostId","deviceId","hostToClientKeyHex","clientToHostKeyHex","record0Hex"}`). The test WRITES the file if `MEMTERM_WRITE_VECTORS=1`, else reads and compares. Generate once, commit the file.
- [ ] **Step 2: Run → FAIL. Step 3: Implement** with CryptoKit (`P256.KeyAgreement`, `HKDF<SHA256>.deriveKey`, `AES.GCM`). SPKI wrapping: prefix the x963 key with the fixed 26-byte DER header for id-ecPublicKey/prime256v1 (`3059301306072a8648ce3d020106082a8648ce3d030107034200`).
- [ ] **Step 4: Run → PASS; run once with `MEMTERM_WRITE_VECTORS=1` to author the vectors; run again → PASS.** **Step 5: Commit** `git commit -m "core: remote crypto (P-256/HKDF/AES-GCM) + shared vectors"`

---

### Task 7: MemtermCore — tree model, output backlog, unlock rate limiter

**Files:**
- Create: `Sources/MemtermCore/Remote/RemoteTree.swift` (move the stub from Task 5 here), `OutputBacklog.swift`, `UnlockRateLimiter.swift`; tests `RemoteTreeTests.swift`, `OutputBacklogTests.swift`, `UnlockRateLimiterTests.swift`

**Interfaces:**
```swift
public struct RemotePane: Codable, Equatable { public var id: String; public var adapter: String; public var cwd: String? }
public struct RemoteTab: Codable, Equatable { public var id: String; public var title: String; public var panes: [RemotePane] }
public struct RemoteWindow: Codable, Equatable { public var id: String; public var tabs: [RemoteTab] }
public struct RemoteWorkspace: Codable, Equatable { public var id, name, color: String; public var locked: Bool; public var parked: Bool; public var windows: [RemoteWindow] }
public struct RemoteTree: Codable, Equatable { public var workspaces: [RemoteWorkspace]; public init(workspaces:) }

public struct OutputBacklog {
    public init(limit: Int = 256 * 1024)
    public mutating func append(_ bytes: Data)        // drops OLDEST whole chunks until under limit
    public mutating func drain() -> Data              // returns everything queued, empties
    public var count: Int { get }
    public var droppedBytes: Int { get }
}
public struct UnlockRateLimiter {
    public init(limit: Int = 5, window: TimeInterval = 60)
    public mutating func allow(deviceId: String, at t: TimeInterval) -> Bool
}
```

- [ ] **Step 1: Failing tests** — tree JSON round trip with a locked workspace; backlog keeps the newest bytes under the cap and reports dropped count; limiter allows 5 then refuses the 6th within 60 s and allows again after.
- [ ] **Step 2: Run → FAIL. Step 3: Implement. Step 4: PASS. Step 5: Commit** `git commit -m "core: remote tree, output backlog, unlock rate limiter"`

---

### Task 8: PaneView taps — output fan-out, input, visible-screen bytes

**Files:**
- Modify: `Sources/memterm/PaneView.swift` (`dataReceived(slice:)` at ~line 205; add members)
- Create: `Sources/memterm/Remote/RemotePaneStream.swift`

**Interfaces:**
- `PaneView`: `var outputTaps: [UUID: (Data) -> Void]` — `dataReceived` calls every tap with the slice AFTER feeding the terminal (the existing behavior is untouched). `func addOutputTap(_ tap: @escaping (Data) -> Void) -> UUID`, `func removeOutputTap(_ id: UUID)`. `func remoteInput(_ bytes: Data)` → `send(data: ArraySlice(bytes))` (the same path the keyboard takes). `func visibleScreenBytes() -> (cols: Int, rows: Int, bytes: Data)` — `ESC[2J ESC[H` then each visible row's `translateToString(trimRight:true, skipNullCellsFollowingWide:true)` (rows `buffer.yDisp ..< yDisp + rows`, via `getScrollInvariantLine(row:)`) joined by `\r\n`, then cursor positioning `ESC[<row>;<col>H` — plain text, no attributes (v1).
- `RemotePaneStream` (app): `init(pane: PaneView, backlogLimit: Int = 262_144)`; `func addViewer(_ id: String, send: @escaping (Data) -> Void)` (sends `screen` first, then streams `output` records; backlog per viewer when `send` reports back-pressure via a returned Bool — keep it simple: `send` is synchronous over the socket queue and the backlog absorbs bursts); `func removeViewer(_ id: String)`; `func input(_ bytes: Data)`; `func resize(cols:rows:)` → `pane.getTerminal().resize(cols:rows:)` through the existing pane resize path (call `pane.setFrameSize` is wrong — use the terminal's `resize(cols:rows:)` then `pane.process` pty size via the existing `LocalProcess` API `pane.process.setSize?` — check `LocalProcessTerminalView.terminalSizeChanged`; if it is not directly callable, resize by resizing the pane's frame to `cols * cellWidth` — decide by reading the file; the probe asserts the pty reports the new size).

- [ ] **Step 1:** There is no headless test for AppKit views; the probe leg (Task 12) gates this. Write the code guided by the interface; keep `dataReceived`'s existing statements first, taps last.
- [ ] **Step 2: `swift build`; run the fresh probe** — `MEMTERM_UI_PROBE=1 MEMTERM_PROBE_MODE=fresh MEMTERM_CONFIG_PATH=$(mktemp -d)/c.toml .build/debug/memterm | grep UIPROBE-PASS` must still pass (no behavior change without taps).
- [ ] **Step 3: Commit** `git commit -m "app: pane output taps, remote input, visible-screen snapshot; RemotePaneStream"`

---

### Task 9: RemoteHost + device store + Settings ▸ Remote

**Files:**
- Create: `Sources/memterm/Remote/RemoteHost.swift`, `RemoteDeviceStore.swift`, `RemoteSettingsSection.swift`
- Modify: `Sources/MemtermCore/Config.swift` (`[remote] enabled=false, relay_url="wss://memterm-relay.fly.dev"`), `Sources/memterm/SettingsWindow.swift` (new "Remote" tab), `Sources/memterm/MemtermApp.swift` (`lazy var remote = RemoteHost(app:)`; `applyConfigLive` → `remote.applyConfig(config)`), `Tests/MemtermCoreTests/ConfigTests.swift` (the two keys)

**Interfaces:**
- `RemoteDeviceStore`: host identity raw private key in the Keychain (`kSecClassGenericPassword`, service `com.memterm.remote`, account `host-identity`); paired devices in `<stateDir>/remote-devices.json` as `[{id, name, publicKeySPKI(b64), pairedAt, lastSeen}]`. `func loadOrCreateIdentity() -> RemoteIdentity`, `var devices: [PairedDevice]`, `func add(_:)`, `func remove(id:)`, `func touch(id:)`.
- `RemoteHost`: `func applyConfig(_ config: Config)` (connect/disconnect), `func startPairing() -> PairingPayload` (`{relayURL, hostId, hostPublicKey(b64), token}` + 120 s expiry; sends `pair-token`), `var onPairRequest: ((name: String, deviceId: String, accept: (Bool) -> Void) -> Void)?` (Settings shows the confirmation), `func revoke(deviceId:)` (removes from store, sends `allowed`, tears down that device's session). Per device session: handshake (`hello` exchanged as the first two inner messages, in the clear inside the envelope, signatures verified against the stored device key), then sealed `RemoteMessage`s. Dispatch: `list` → build `RemoteTree` from `app.memory.store.listWorkspaces()` + `app.hosts` (windows) + `host.tabs` + `tab.allPanes()` (`locked` always false in this project); `attach` → `RemotePaneStream` for that pane (`app.controllers.flatMap { $0.allPanes() }.first { $0.paneId == id }`), refuse `locked`/`unknown-pane`; `newTab` → `app.newWindowForTab`-equivalent in that workspace via `app.registerController` + host `attach` (see `ExtensionHost.openTab` for the exact pattern) then `tree-changed`; `unlock` → rate limiter then `refused locked` (no locks exist yet); `tree-changed` pushed when `app.refreshWorkspaceChips()` runs (hook one call there).
- Settings ▸ Remote: switch (`remote.enabled`), relay URL field, "Pair a device…" (QR via `CIFilter(name:"CIQRCodeGenerator")` of the pairing URL `"<relayURL>/#pair=<base64url JSON payload>"`), devices table (name, last seen, Remove), status line (connected / offline / off).
- Automated runs: `RemoteHost.applyConfig` never connects when `ProbeSupport.isUIProbe || ProbeSupport.isSmoke` unless `MEMTERM_REMOTE_RELAY_URL` is set (the probe sets it to its local relay).

- [ ] **Step 1: Config tests** for the two keys (defaults, parse, round trip) → FAIL → implement → PASS.
- [ ] **Step 2: Implement the three files** per the interfaces. WebSocket: `URLSession.shared.webSocketTask(with: URL)`, receive loop on a serial queue, reconnect with backoff 1 s → 30 s.
- [ ] **Step 3: `swift build`, `swift test`, fresh probe still PASS (remote off by default).**
- [ ] **Step 4: Commit** `git commit -m "app: RemoteHost (relay socket, pairing, sessions), device store, Settings ▸ Remote"`

---

### Task 10: Web client — crypto + codec against the shared vectors

**Files:**
- Create: `relay/web/src/crypto.ts`, `relay/web/src/codec.ts`, `relay/web/test/vectors.test.ts`

**Interfaces:**
- `crypto.ts`: `generateIdentity(): Promise<{privateKey: CryptoKey, publicKeySPKI: Uint8Array, id: string}>` (ECDSA P-256; id = same base32 as the relay), `signNonce(privateKey, nonce)`, `makeHello(identityPrivateKey)` → `{hello:{ephemeralRaw(b64), signature(b64)}, ephemeralPrivate}` (ephemeral is an ECDH key; sign its raw 65-byte point with the identity key), `verifyHello(hello, peerSPKI)`, `deriveKeys(myEphemeralPrivate, peerEphemeralRaw, hostId, deviceId, iAmHost=false)` → `{sendKey, recvKey}` (AES-GCM CryptoKeys; client send = clientToHost = okm[32..64]), `class SessionKeys { seal(plain): Promise<Uint8Array>; open(record): Promise<Uint8Array> }` with the same counter-nonce rule.
- `codec.ts`: `encodeMessage(m: RemoteMessage): string`, `decodeMessage(s: string): RemoteMessage | undefined`, `RemoteMessage` as a TS discriminated union mirroring Task 5's tags.

- [ ] **Step 1: Failing test** loads `../../../Tests/vectors/remote-crypto-vectors.json` (path relative to the test file), imports the fixed shared secret through `deriveKeys`' inner HKDF helper (`export async function hkdfKeys(sharedSecret: Uint8Array, hostId, deviceId)` — exported for the test), asserts both key hexes match, and that sealing `"hello"` with counter 0 yields `record0Hex`.
- [ ] **Step 2: Run (`npm test`) → FAIL. Step 3: Implement with `crypto.subtle` (works in Node 20 and browsers). Step 4: PASS. Step 5: Commit** `git commit -m "web: crypto + codec, proven against the Swift vectors"`

---

### Task 11: Web client — page: pair, list, attach with xterm.js, resize, offline

**Files:**
- Modify: `relay/web/index.html`; Create: `relay/web/src/app.ts`, `relay/web/src/relay.ts` (WebSocket + envelope + auth), `relay/web/style.css`

**Behavior:**
- On load: identity from IndexedDB (`memterm-remote` db, `keys` store) or generate. If `location.hash` starts with `#pair=`, decode the payload, connect to `/client`, authenticate, send `pair`, show "Waiting for the host to accept…", then store `{hostId, hostPublicKey}` in IndexedDB and clear the hash.
- Otherwise: connect, authenticate, handshake with the stored host, send `list`, render the tree (workspace → tabs → panes as buttons; locked shown with a lock glyph and disabled). Click a pane → `attach`; on `screen` write bytes to a fresh `Terminal` (xterm.js) sized to the given cols/rows; `output` → `term.write`; `term.onData` → `input`. "Fit to me" button → `resize` with `fitAddon.proposeDimensions()`. Back button → `detach`.
- `offline` → banner "Host offline since <time>"; `online` → re-`list`. Relay socket close → banner "Relay unreachable", retry with backoff 1 s → 30 s.
- `refused` → toast with the reason.

- [ ] **Step 1: Implement** (no framework; ~300 lines). `npm run web` bundles to `web/dist/app.js`; `index.html` loads `dist/app.js` and xterm's CSS from the bundle.
- [ ] **Step 2: Manual check against the local relay** (`npm start` + open `http://127.0.0.1:8787/`): the page loads, shows "Not paired" without a hash. Automated coverage arrives in Task 12.
- [ ] **Step 3: Commit** `git commit -m "web: pairing, tree, attach with xterm.js, resize, offline"`

---

### Task 12: End-to-end probe leg + verify.sh

**Files:**
- Modify: `Sources/memterm/ProbeLegs.swift` (new `addRemoteSteps`), `scripts/verify.sh`
- Create: `Sources/memterm/Remote/RemoteProbeClient.swift` (headless Swift client: relay socket + auth + pairing + handshake + `RemoteMessage`s — reuses MemtermCore; ~150 lines)

**Leg `remote-end-to-end` (fresh mode; skipped with a reason unless `node` is on PATH and `relay/node_modules` exists):**
1. Start the relay: `Process` running `node relay/dist/src/server.js` with `PORT=0`? — `PORT=0` cannot be reported back; instead pick a free port in Swift (bind/close a listener) and pass it. Wait for `/healthz`.
2. `applyConfigLive` with `remote.enabled = true`, `relay_url = ws://127.0.0.1:<port>`; set `MEMTERM_REMOTE_RELAY_URL` semantics by passing the URL through config (the automated-run guard accepts a loopback URL).
3. `remote.startPairing()` → payload; `RemoteProbeClient.pair(payload)` while the leg auto-accepts via `remote.onPairRequest` (assert the device name arrives).
4. Client `list` → assert the tree contains the key host's selected pane id.
5. Client `attach` → assert a `screen` arrives with `cols == pane cols`; client `input("echo remote-probe\r")` → wait for `output` containing `remote-probe`; assert `pane.scrollbackText(maxLines: 50)` contains `remote-probe` (the bytes reached the real pty).
6. Client `resize 100x30` → assert `resized 100 30` and the pane's terminal reports 100 cols.
7. Kill the relay process → assert the host reconnect state is "offline"/backoff; restart relay → host reconnects (`remote.probeState == "connected"`).
8. `remote.revoke(deviceId)` → client's next envelope gets `refused not-allowed`.
9. Print `UIPROBE-REMOTE paired=true listed=true attached=true echo_roundtrip=true resized=true reconnected=true revoked=true`; tear down (disable remote, stop relay).

- [ ] **Step 1: Write the leg and `RemoteProbeClient`. Step 2: `cd relay && npm run build` then run the fresh probe → the new line must print with every field true.** **Step 3: verify.sh**: `check "fresh-default-remote" "$LOG/probe-fresh-default.log" "UIPROBE-REMOTE paired=true listed=true attached=true echo_roundtrip=true resized=true reconnected=true revoked=true"` and a preflight that builds the relay (`npm ci && npm run build`) when node is present, else the leg's skip line is accepted.
- [ ] **Step 4: Commit** `git commit -m "probe: remote end-to-end leg (local relay, headless client) + verify.sh"`

---

### Task 13: Fly deploy in the release workflow + docs

**Files:**
- Modify: `.github/workflows/release.yml` (job `relay-deploy`: `superfly/flyctl-actions/setup-flyctl@master`, `flyctl deploy --remote-only` in `relay/`, `FLY_API_TOKEN` secret, gated on the secret being set), `README.md` (a "Remote attach" section: enable, pair by QR, what the relay sees, self-hosting = `fly launch` in `relay/`), `REQUIREMENTS.md` (FR-60: remote attach, with the constraints above)

- [ ] **Step 1: Edit the three files. Step 2: `fly apps create memterm-relay` once (founder) and `fly deploy` from `relay/` to prove the container runs; set `FLY_API_TOKEN` (`fly tokens create deploy`) as a repo secret.** **Step 3: Tag a release; the relay deploys; Settings' default relay URL is `wss://memterm-relay.fly.dev`.** **Step 4: Commit** `git commit -m "release: deploy the relay to Fly; docs for remote attach"`

---

## Self-review (done while writing)

- **Spec coverage:** relay (T1–T4), crypto (T6, T10 with shared vectors), inner protocol + lock hooks (T5, T7, T9 `unlock`/`locked`), host + pane streaming + screen snapshot + backlog (T7–T9), pairing UX + device list + revocation (T9, T3), multi-viewer fan-out + size rule (T8 `RemotePaneStream` fans out; the "host window wins, Fit-to-me resizes" rule is T8 `resize` + T11 button), failure handling (T3 offline/online, T9 backoff, T12 kill/restart), testing (every task), Fly deploy (T4, T13). Deferred items stay deferred.
- **Placeholders:** none left; every step has code or an exact command.
- **Type consistency:** `RemoteMessage` tags in T5 = codec in T10; `RemoteTree` fields T5/T7/T9/T11; `hostId` derivation identical in T2/T6/T10 (base32 of SHA-256 over SPKI, 16 chars); key split (host→client = okm[0..<32]) identical in T6/T10.
