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
