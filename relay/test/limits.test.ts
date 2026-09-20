import { test } from "node:test";
import assert from "node:assert/strict";
import type http from "node:http";
import { WebSocket } from "ws";
import { startRelay, clientIp } from "../src/server.js";
import { parseInbound, MAX_NAME_BYTES } from "../src/envelope.js";
import { Registry, MAX_PAIRINGS_PER_HOST, MAX_ALLOWED_DEVICES, LAST_SEEN_TTL_MS } from "../src/registry.js";
import { connectAuthed, next, b64, routingToken, PROOF } from "./helpers.js";

const WEB = new URL("../web", import.meta.url).pathname;

/** A syntactically valid peer id: 16 chars of the lower-case base32 alphabet. */
function peerId(seed: string): string {
  return (seed + "aaaaaaaaaaaaaaaa").slice(0, 16);
}

/** A distinct valid peer id per number — base32 digits, so no collisions. */
function nthPeerId(n: number): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  let out = "";
  let value = n;
  for (let i = 0; i < 16; i++) {
    out = alphabet[value % 32] + out;
    value = Math.floor(value / 32);
  }
  return out;
}

// Security review H1: authenticating as a host costs an attacker nothing,
// and afterwards every map in the registry was unbounded -- one socket
// looping `pair-token` with 1 MiB tokens filled the 512 MB machine in
// seconds. These pin the four bounds that closed it.

test("a token that is not 22 chars of base64url is rejected before it is stored", () => {
  const good = routingToken(5);
  assert.equal(good.length, 22);
  assert.deepEqual(parseInbound({ type: "pair-token", token: good }), { type: "pair-token", token: good });

  for (const bad of [
    "x".repeat(1024 * 1024), // the flood
    "x".repeat(23),
    "x".repeat(21),
    "",
    "T1",
    "AAAAAAAAAAAAAAAAAAAA==", // padded
    "AAAAAAAAAAAAAAAAAAAA+/", // standard-base64 alphabet, not base64url
    good + "\n",
  ]) {
    assert.equal(parseInbound({ type: "pair-token", token: bad }), undefined, `accepted token ${JSON.stringify(bad.slice(0, 32))}`);
    assert.equal(
      parseInbound({ type: "pair", token: bad, publicKey: "AA==", name: "n", proof: PROOF }),
      undefined
    );
  }

  // A pair with no proof at all is not a message the relay will carry.
  assert.equal(parseInbound({ type: "pair", token: good, publicKey: "AA==", name: "n" }), undefined);
});

test("a host cannot accumulate pairings: the oldest is dropped past the cap", () => {
  const r = new Registry();
  for (let i = 0; i < 50; i++) r.createPairing("h1", routingToken(i), 120_000, 1_000 + i);
  assert.equal(r.pairingCount, MAX_PAIRINGS_PER_HOST);
  // The newest two survive; the first one minted is long gone.
  assert.equal(r.consumePairing(routingToken(0), 2_000), undefined);
  assert.equal(r.consumePairing(routingToken(49), 2_000)?.hostId, "h1");
  assert.equal(r.consumePairing(routingToken(48), 2_000)?.hostId, "h1");

  // Two hosts each keep their own budget rather than sharing one.
  const r2 = new Registry();
  r2.createPairing("h1", routingToken(1), 120_000, 0);
  r2.createPairing("h2", routingToken(2), 120_000, 0);
  r2.createPairing("h2", routingToken(3), 120_000, 0);
  assert.equal(r2.consumePairing(routingToken(1), 1_000)?.hostId, "h1");
});

test("every insert sweeps expired pairings and day-old lastSeen rows", () => {
  const r = new Registry();
  r.createPairing("stale", routingToken(1), 120_000, 0);
  r.markSeen("stale", 0);
  assert.equal(r.pairingCount, 1);

  // A different host inserting much later sweeps the abandoned entry.
  const later = 200_000;
  r.createPairing("fresh", routingToken(2), 120_000, later);
  assert.equal(r.pairingCount, 1);
  assert.equal(r.consumePairing(routingToken(1), later), undefined);

  assert.equal(r.lastSeen("stale"), 0);
  r.createPairing("fresh", routingToken(3), 120_000, LAST_SEEN_TTL_MS + 1);
  assert.equal(r.lastSeen("stale"), undefined);
});

// H1 residual, from the re-review: `createPairing` was the only sweep
// site, so on a relay where nobody pairs, every throwaway host id left a
// `lastSeenAt` row behind permanently. Host auth now sweeps too — the same
// event that adds a row.
test("a host authenticating ages out stale entries even when nobody pairs", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const stale = nthPeerId(1);
    const recent = nthPeerId(2);
    relay.registry.markSeen(stale, Date.now() - LAST_SEEN_TTL_MS - 1_000);
    relay.registry.markSeen(recent, Date.now());
    relay.registry.createPairing(stale, routingToken(1), -1_000, Date.now()); // already expired
    assert.equal(relay.registry.pairingCount, 1);

    // No pairing anywhere in this test: a host simply connects.
    const host = await connectAuthed(relay.port, "host", { allowed: [] });

    assert.equal(relay.registry.lastSeen(stale), undefined, "a day-old lastSeen row survived");
    assert.ok(relay.registry.lastSeen(recent), "a fresh lastSeen row was swept");
    assert.ok(relay.registry.lastSeen(host.id), "the connecting host's own row is missing");
    assert.equal(relay.registry.pairingCount, 0, "an expired pairing survived");
  } finally {
    await relay.close();
  }
});

test("an announced allow-list is capped", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    // Well-formed and DISTINCT ids, so only the count cap can trim them.
    const many = Array.from({ length: 5_000 }, (_, i) => nthPeerId(i));
    assert.equal(new Set(many).size, 5_000);
    const host = await connectAuthed(relay.port, "host", { allowed: many });
    assert.equal(relay.registry.host(host.id)!.allowed.size, MAX_ALLOWED_DEVICES);

    host.ws.send(JSON.stringify({ type: "allowed", devices: many }));
    // Give the message a turn to land before reading the registry.
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(relay.registry.host(host.id)!.allowed.size, MAX_ALLOWED_DEVICES);
  } finally {
    await relay.close();
  }
});

// Security re-review N3: entry counts were capped but each id string was
// not, so 64 ids of ~16 KB fit inside the frame limit and were retained in
// both `allowed` and `watchers` — roughly 2 MiB held per host socket.

test("ids that are not 16 base32 characters are refused or filtered out", () => {
  const good = peerId("abcd");
  const other = peerId("wxyz");

  assert.deepEqual(parseInbound({ type: "env", to: good, from: other, payload: "AQID" }),
                   { type: "env", to: good, from: other, payload: "AQID" });
  assert.deepEqual(parseInbound({ type: "pair-answer", deviceId: good, accept: true }),
                   { type: "pair-answer", deviceId: good, accept: true });

  for (const bad of [
    "x".repeat(16 * 1024), // the flood
    "x".repeat(17),
    "x".repeat(15),
    "",
    "dA",
    "someone-else",
    "ABCDEFGHIJKLMNOP", // upper case is not the alphabet auth.ts emits
    "abcdefghijklmno1", // 0/1/8/9 are not in RFC 4648's base32 alphabet
  ]) {
    // A single-id field has nothing left without it: the message is refused.
    assert.equal(parseInbound({ type: "env", to: bad, from: good, payload: "AQID" }), undefined,
                 `accepted to=${JSON.stringify(bad.slice(0, 24))}`);
    assert.equal(parseInbound({ type: "env", to: good, from: bad, payload: "AQID" }), undefined);
    assert.equal(parseInbound({ type: "pair-answer", deviceId: bad, accept: true }), undefined);

    // A LIST is filtered instead: dropping the whole message would revoke
    // every real device the host named alongside the bad entry.
    assert.deepEqual(parseInbound({ type: "allowed", devices: [good, bad, other] }),
                     { type: "allowed", devices: [good, other] });
  }

  // Non-strings in a list go the same way as malformed strings.
  assert.deepEqual(parseInbound({ type: "allowed", devices: [good, 42, null, {}, other] }),
                   { type: "allowed", devices: [good, other] });
});

test("a device name is capped in bytes before it is forwarded", () => {
  const token = routingToken(7);
  const base = { type: "pair", token, publicKey: "AA==", proof: PROOF };

  const long = parseInbound({ ...base, name: "x".repeat(5_000) });
  assert.ok(long && long.type === "pair");
  assert.equal(Buffer.from(long.name, "utf8").length, MAX_NAME_BYTES);

  // A short name is untouched, multi-byte characters and all.
  const short = parseInbound({ ...base, name: "Riley's iPhone ☎" });
  assert.ok(short && short.type === "pair");
  assert.equal(short.name, "Riley's iPhone ☎");

  // Cutting UTF-8 at a byte boundary must not leave half a code point.
  const emoji = parseInbound({ ...base, name: "📱".repeat(100) });
  assert.ok(emoji && emoji.type === "pair");
  assert.ok(Buffer.from(emoji.name, "utf8").length <= MAX_NAME_BYTES);
  assert.doesNotMatch(emoji.name, /�/);
});

test("the fly-client-ip header is only believed when TRUST_PROXY says so", () => {
  const req = {
    headers: { "fly-client-ip": "203.0.113.9" },
    socket: { remoteAddress: "10.0.0.1" },
  } as unknown as http.IncomingMessage;

  assert.equal(clientIp(req, true), "203.0.113.9");
  // Untrusted: a client-settable header must not choose its own bucket.
  assert.equal(clientIp(req, false), "10.0.0.1");

  const bare = { headers: {}, socket: { remoteAddress: "10.0.0.2" } } as unknown as http.IncomingMessage;
  assert.equal(clientIp(bare, true), "10.0.0.2");
  assert.equal(clientIp(bare, false), "10.0.0.2");

  // An over-long header value is not a bucket key either.
  const huge = {
    headers: { "fly-client-ip": "x".repeat(4_096) },
    socket: { remoteAddress: "10.0.0.3" },
  } as unknown as http.IncomingMessage;
  assert.equal(clientIp(huge, true), "10.0.0.3");
});

test("rotating fly-client-ip does not buy extra connections when the proxy is untrusted", async () => {
  // Default (no TRUST_PROXY in the environment): the cap counts the socket
  // address, so every forged header lands in the same bucket.
  const relay = await startRelay({ port: 0, webRoot: WEB, maxConnectionsPerIp: 1 });
  try {
    const first = new WebSocket(`ws://127.0.0.1:${relay.port}/client`, {
      headers: { "fly-client-ip": "203.0.113.1" },
    });
    first.once("error", () => {});
    await new Promise<void>((resolve) => first.once("open", () => resolve()));

    const second = new WebSocket(`ws://127.0.0.1:${relay.port}/client`, {
      headers: { "fly-client-ip": "203.0.113.2" }, // a different invented bucket
    });
    second.once("error", () => {});
    const outcome = await new Promise<string>((resolve) => {
      second.once("close", () => resolve("closed"));
      second.once("open", () => resolve("open"));
    });
    assert.equal(outcome, "closed", "a rotated header must not escape the per-IP cap");
    first.close();
  } finally {
    await relay.close();
  }
});

test("connections past the per-IP cap are refused, and a close frees a slot", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB, maxConnectionsPerIp: 2 });
  try {
    const first = await connectAuthed(relay.port, "client");
    const second = await connectAuthed(relay.port, "client");

    const third = new WebSocket(`ws://127.0.0.1:${relay.port}/client`);
    third.once("error", () => {});
    const refused = await new Promise<string>((resolve) => {
      third.once("close", () => resolve("closed"));
      third.once("open", () => resolve("open"));
    });
    assert.equal(refused, "closed", "a third connection from the same IP must be destroyed");

    // Freeing a slot lets the next one in, so this is a cap, not a ban.
    second.ws.close();
    await new Promise((r) => setTimeout(r, 50));
    const fourth = await connectAuthed(relay.port, "client");
    assert.ok(fourth.id);
    first.ws.close();
    fourth.ws.close();
  } finally {
    await relay.close();
  }
});

test("a pair-token with a well-formed token still pairs end to end", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const token = routingToken(11);
    const host = await connectAuthed(relay.port, "host", { allowed: [] });
    host.ws.send(JSON.stringify({ type: "pair-token", token }));
    const dev = await connectAuthed(relay.port, "client", {});
    dev.ws.send(JSON.stringify({ type: "pair", token, publicKey: b64(dev.spki), name: "phone", proof: PROOF }));
    assert.equal((await next(host.ws, "pair-request")).deviceId, dev.id);
  } finally {
    await relay.close();
  }
});
