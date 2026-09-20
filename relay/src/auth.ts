// No `node:crypto` import: this module is also imported (transitively, via
// web/src/crypto.ts's `idFromPublicKey`) by the browser-bundled web client,
// so it uses only `crypto.subtle`/`crypto.getRandomValues` -- identical
// globals in Node 20 (globalThis.crypto) and in every browser.
const ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";
export function base32(bytes: Uint8Array): string {
  let bits = 0, value = 0, out = "";
  for (const b of bytes) { value = (value << 8) | b; bits += 8; while (bits >= 5) { out += ALPHABET[(value >>> (bits - 5)) & 31]; bits -= 5; } }
  if (bits > 0) out += ALPHABET[(value << (5 - bits)) & 31];
  return out;
}

// TypeScript (with @types/node's global Uint8Array override alongside the
// DOM lib) infers plain `new Uint8Array(n)` as `Uint8Array<ArrayBufferLike>`,
// which the DOM `BufferSource` parameter type of `SubtleCrypto` methods
// rejects at the type level even though the runtime value is fine in both
// Node and every browser. Same narrowing as web/src/crypto.ts's `bs()`.
function bs(bytes: Uint8Array): BufferSource {
  return bytes as unknown as BufferSource;
}

export async function idFromPublicKey(spki: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bs(spki)));
  return base32(digest).slice(0, 16);
}
export function randomNonce(): Uint8Array { return crypto.getRandomValues(new Uint8Array(32)); }
export async function verifyAuth(spki: Uint8Array, nonce: Uint8Array, signature: Uint8Array): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey("spki", bs(spki), { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, bs(signature), bs(nonce));
  } catch { return false; }
}
