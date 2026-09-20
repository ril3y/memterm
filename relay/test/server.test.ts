import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { WebSocket } from "ws";
import { startRelay } from "../src/server.js";
import { idFromPublicKey } from "../src/auth.js";
import { connectAuthed, next } from "./helpers.js";

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

// Security review M3: no CSP, no nosniff, no HSTS on any response. None of
// it saves a client from a relay that is hostile in the first place (it
// serves the client), but it is the only defence in depth there is.
test("every response carries the security headers", async () => {
  const relay = await startRelay({ port: 0, webRoot: new URL("../web", import.meta.url).pathname });
  try {
    for (const path of ["/healthz", "/", "/index.html", "/nope.js", "/../package.json"]) {
      const res = await fetch(`http://127.0.0.1:${relay.port}${path}`);
      const csp = res.headers.get("content-security-policy");
      assert.ok(csp, `no CSP on ${path}`);
      assert.match(csp!, /default-src 'self'/);
      assert.match(csp!, /connect-src 'self' wss: ws:/);
      assert.match(csp!, /img-src 'self' data:/);
      assert.match(csp!, /style-src 'self' 'unsafe-inline'/);
      // index.html has an inline <style> but no inline <script>, so
      // scripts stay on the un-loosened default-src.
      assert.doesNotMatch(csp!, /script-src/);
      assert.equal(res.headers.get("x-content-type-options"), "nosniff", `no nosniff on ${path}`);
      assert.equal(res.headers.get("strict-transport-security"), "max-age=31536000", `no HSTS on ${path}`);
    }
  } finally {
    await relay.close();
  }
});

function b64(bytes: Uint8Array): string { return Buffer.from(bytes).toString("base64"); }

test("a host that answers the challenge with a valid signature is authed and registered", async () => {
  const relay = await startRelay({ port: 0, webRoot: new URL("../web", import.meta.url).pathname });
  try {
    const kp = await webcrypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const spki = new Uint8Array(await webcrypto.subtle.exportKey("spki", kp.publicKey));
    const expectedId = await idFromPublicKey(spki);

    const ws = new WebSocket(`ws://127.0.0.1:${relay.port}/host`);
    const authed = await new Promise<any>((resolve, reject) => {
      ws.once("error", reject);
      ws.once("message", async (raw: Buffer) => {
        const challenge = JSON.parse(raw.toString());
        assert.equal(challenge.type, "challenge");
        const nonce = new Uint8Array(Buffer.from(challenge.nonce, "base64"));
        const signature = new Uint8Array(
          await webcrypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, kp.privateKey, nonce)
        );
        ws.once("message", (raw2: Buffer) => resolve(JSON.parse(raw2.toString())));
        ws.send(JSON.stringify({ type: "auth", publicKey: b64(spki), signature: b64(signature), allowed: ["dA"] }));
      });
    });
    assert.equal(authed.type, "authed");
    assert.equal(authed.id, expectedId);
    assert.ok(relay.registry.host(expectedId));
    assert.ok(relay.registry.host(expectedId)!.allowed.has("dA"));
    ws.close();
  } finally {
    await relay.close();
  }
});

test("a bad signature is rejected with close code 4001", async () => {
  const relay = await startRelay({ port: 0, webRoot: new URL("../web", import.meta.url).pathname });
  try {
    const kp = await webcrypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const spki = new Uint8Array(await webcrypto.subtle.exportKey("spki", kp.publicKey));

    const ws = new WebSocket(`ws://127.0.0.1:${relay.port}/host`);
    const closeCode = await new Promise<number>((resolve, reject) => {
      ws.once("error", reject);
      ws.once("message", (raw: Buffer) => {
        const challenge = JSON.parse(raw.toString());
        assert.equal(challenge.type, "challenge");
        const badSignature = new Uint8Array(64); // all zeros: never a valid ECDSA signature
        ws.send(JSON.stringify({ type: "auth", publicKey: b64(spki), signature: b64(badSignature), allowed: [] }));
      });
      ws.once("close", (code: number) => resolve(code));
    });
    assert.equal(closeCode, 4001);
  } finally {
    await relay.close();
  }
});

// Final-review Important 5: the relay is a public endpoint on a 512 MB Fly
// machine with no payload cap, no auth deadline, and no way to notice a peer
// whose TCP connection died silently — a host asleep behind a dead socket
// looked "online" forever and an unauthenticated socket could sit open
// indefinitely. Both timers are configurable so these tests run in
// milliseconds instead of the real 10 s / 30 s production defaults.

test("a socket that never completes auth is terminated after the auth deadline", async () => {
  const relay = await startRelay({
    port: 0,
    webRoot: new URL("../web", import.meta.url).pathname,
    authDeadlineMs: 30,
  });
  try {
    const ws = new WebSocket(`ws://127.0.0.1:${relay.port}/host`);
    ws.once("error", () => {}); // an abrupt server-side terminate() can surface as a local reset
    await new Promise<void>((resolve) => {
      // Never answers the challenge — the deadline alone must close this.
      ws.once("close", () => resolve());
    });
  } finally {
    await relay.close();
  }
});

test("a host that stops answering pings is terminated and its watchers get offline", async () => {
  const relay = await startRelay({
    port: 0,
    webRoot: new URL("../web", import.meta.url).pathname,
    pingIntervalMs: 20,
  });
  try {
    const watcher = await connectAuthed(relay.port, "client");
    const host = await connectAuthed(relay.port, "host", { allowed: [watcher.id] });
    assert.ok(relay.registry.host(host.id));

    // Simulate a dead-but-still-open TCP connection (the mini asleep, a
    // backgrounded phone): pause reading on the host's socket so incoming
    // ping frames are never parsed, and therefore never auto-ponged, while
    // the connection itself stays up.
    (host.ws as unknown as { _socket: { pause(): void } })._socket.pause();
    host.ws.once("error", () => {});

    const offline = await next(watcher.ws, "offline");
    assert.equal(offline.hostId, host.id);
    assert.equal(relay.registry.host(host.id), undefined);
  } finally {
    await relay.close();
  }
});

test("an oversized frame closes the socket", async () => {
  const relay = await startRelay({ port: 0, webRoot: new URL("../web", import.meta.url).pathname });
  try {
    const peer = await connectAuthed(relay.port, "client");
    const closed = new Promise<number>((resolve) => {
      peer.ws.once("close", (code: number) => resolve(code));
    });
    peer.ws.once("error", () => {});
    // 2 MiB, well over the relay's 1 MiB maxPayload.
    peer.ws.send(Buffer.alloc(2 * 1024 * 1024));
    const code = await closed;
    assert.equal(code, 1009); // RFC 6455 "Message Too Big"
  } finally {
    await relay.close();
  }
});
