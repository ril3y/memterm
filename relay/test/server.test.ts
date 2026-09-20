import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { WebSocket } from "ws";
import { startRelay } from "../src/server.js";
import { idFromPublicKey } from "../src/auth.js";

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
