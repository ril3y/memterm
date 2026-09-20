import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import { readFileSync } from "node:fs";
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

// Final-review Important 6: the test above only proves idFromPublicKey
// produces SOMETHING shaped like an id — a regression in the base32 or the
// `.slice(0, 16)` would still pass it. This runs from the compiled
// `dist/test/auth.test.js`, which sits one directory shallower than
// `dist/web/test/` (see vectors.test.ts's own comment), hence three `../`
// rather than four to reach the repo root from here.
const vectorsUrl = new URL("../../../Tests/vectors/remote-crypto-vectors.json", import.meta.url);
const vectors = JSON.parse(readFileSync(vectorsUrl, "utf8")) as {
  deviceSPKIHex: string;
  peerId: string;
};

function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}

test("idFromPublicKey of the pinned WebCrypto-exported SPKI matches the pinned peerId", async () => {
  const spki = fromHex(vectors.deviceSPKIHex);
  assert.equal(spki.length, 91);
  assert.equal(await idFromPublicKey(spki), vectors.peerId);
});
