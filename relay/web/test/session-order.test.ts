// Field bug 2026-09-22 ("type a letter and it kicks me out"): seal() read
// the send counter, awaited the encrypt, then incremented — so two records
// sealed in one turn shared a nonce and the host refused the second as a
// replay; open() had the same shape on the receive side. These pin the
// fix: counters are reserved synchronously and records resolve in order.
import { test } from "node:test";
import assert from "node:assert/strict";
import { SessionKeys } from "../src/crypto.js";

async function aesKey(fill: number): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", new Uint8Array(32).fill(fill), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

function nonceOf(record: Uint8Array): bigint {
  let n = 0n;
  for (const b of record.slice(4, 12)) n = (n << 8n) | BigInt(b);
  return n;
}

test("concurrent seals never share a nonce and resolve in counter order", async () => {
  const k = await aesKey(1);
  const a = new SessionKeys(k, await aesKey(2));
  const enc = new TextEncoder();
  // Fire five seals in ONE turn, without awaiting between them.
  const records = await Promise.all([0, 1, 2, 3, 4].map((i) => a.seal(enc.encode(`m${i}`))));
  const nonces = records.map(nonceOf);
  assert.deepEqual(nonces, [0n, 1n, 2n, 3n, 4n]);
  assert.equal(new Set(nonces.map(String)).size, 5);
});

test("concurrent opens of in-order records all succeed", async () => {
  const k1 = await aesKey(3);
  const k2 = await aesKey(4);
  const sender = new SessionKeys(k1, k2);
  const receiver = new SessionKeys(k2, k1);
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  const records = await Promise.all([0, 1, 2, 3].map((i) => sender.seal(enc.encode(`chunk${i}`))));
  // Deliver all four in the same turn, as a burst of output arrives.
  const plains = await Promise.all(records.map((r) => receiver.open(r)));
  assert.deepEqual(plains.map((p) => dec.decode(p)), ["chunk0", "chunk1", "chunk2", "chunk3"]);
});

test("a genuinely replayed record is still refused without advancing", async () => {
  const k1 = await aesKey(5);
  const k2 = await aesKey(6);
  const sender = new SessionKeys(k1, k2);
  const receiver = new SessionKeys(k2, k1);
  const enc = new TextEncoder();
  const first = await sender.seal(enc.encode("one"));
  const second = await sender.seal(enc.encode("two"));
  await receiver.open(first);
  await assert.rejects(receiver.open(first), /replay/);
  // The failed replay did not consume the counter: the real next record opens.
  assert.equal(new TextDecoder().decode(await receiver.open(second)), "two");
});
