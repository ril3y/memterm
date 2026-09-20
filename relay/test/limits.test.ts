import { test } from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";
import { startRelay } from "../src/server.js";
import { parseInbound } from "../src/envelope.js";
import { Registry, MAX_PAIRINGS_PER_HOST, MAX_ALLOWED_DEVICES, LAST_SEEN_TTL_MS } from "../src/registry.js";
import { connectAuthed, next, b64, routingToken, PROOF } from "./helpers.js";

const WEB = new URL("../web", import.meta.url).pathname;

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

test("an announced allow-list is capped", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const many = Array.from({ length: 5_000 }, (_, i) => `device-${i}`);
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
