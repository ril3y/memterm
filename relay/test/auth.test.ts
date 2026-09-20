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
