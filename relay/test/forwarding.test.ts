import { test } from "node:test";
import assert from "node:assert/strict";
import { startRelay } from "../src/server.js";
import { connectAuthed, next, b64, routingToken, PROOF } from "./helpers.js";

const WEB = new URL("../web", import.meta.url).pathname;

test("pairing, forwarding both ways, host-drop -> offline, revocation", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const token = routingToken(1);
    const host = await connectAuthed(relay.port, "host", { allowed: [] });
    host.ws.send(JSON.stringify({ type: "pair-token", token }));

    const dev = await connectAuthed(relay.port, "client", {});
    dev.ws.send(JSON.stringify({ type: "pair", token, publicKey: b64(dev.spki), name: "phone", proof: PROOF }));

    const req = await next(host.ws, "pair-request");
    assert.equal(req.deviceId, dev.id);
    assert.equal(req.publicKey, b64(dev.spki));
    assert.equal(req.name, "phone");
    // The proof is forwarded verbatim: only the host can check it, since
    // only the host holds the token's secret half (security review C2).
    assert.equal(req.proof, PROOF);

    host.ws.send(JSON.stringify({ type: "pair-answer", deviceId: dev.id, accept: true }));
    const paired = await next(dev.ws, "paired");
    assert.equal(paired.hostId, host.id);
    assert.equal(paired.hostPublicKey, b64(host.spki));

    dev.ws.send(JSON.stringify({ type: "env", to: host.id, from: dev.id, payload: "AQID" }));
    assert.equal((await next(host.ws, "env")).payload, "AQID");

    host.ws.send(JSON.stringify({ type: "env", to: dev.id, from: host.id, payload: "BAUG" }));
    assert.equal((await next(dev.ws, "env")).payload, "BAUG");

    host.ws.send(JSON.stringify({ type: "allowed", devices: [] })); // revoke
    dev.ws.send(JSON.stringify({ type: "env", to: host.id, from: dev.id, payload: "AQID" }));
    assert.equal((await next(dev.ws, "refused")).reason, "not-allowed");

    host.ws.close();
    assert.equal((await next(dev.ws, "offline")).hostId, host.id);
  } finally {
    await relay.close();
  }
});

// Security review L2: "that host isn't connected" and "that host never
// allowed you" used to be distinguishable, which made the relay a
// host-existence oracle. One reason now answers both.
test("an unknown host and a disallowed host are refused identically", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const host = await connectAuthed(relay.port, "host", { allowed: [] });
    const dev = await connectAuthed(relay.port, "client", {});

    // A host id that has never existed.
    dev.ws.send(JSON.stringify({ type: "env", to: "aaaaaaaaaaaaaaaa", from: dev.id, payload: "AQID" }));
    assert.equal((await next(dev.ws, "refused")).reason, "not-allowed");

    // A host that is connected but has not allowed this device.
    dev.ws.send(JSON.stringify({ type: "env", to: host.id, from: dev.id, payload: "AQID" }));
    assert.equal((await next(dev.ws, "refused")).reason, "not-allowed");

    // And the same in the host->client direction.
    host.ws.send(JSON.stringify({ type: "env", to: "bbbbbbbbbbbbbbbb", from: host.id, payload: "AQID" }));
    assert.equal((await next(host.ws, "refused")).reason, "not-allowed");
  } finally {
    await relay.close();
  }
});

test("a forged from is dropped and the socket closed", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const host = await connectAuthed(relay.port, "host", { allowed: [] });
    const dev = await connectAuthed(relay.port, "client", {});

    const closeCode = new Promise<number>((resolve) => dev.ws.once("close", resolve));
    dev.ws.send(JSON.stringify({ type: "env", to: host.id, from: "someone-else", payload: "AQID" }));
    assert.equal(await closeCode, 4003);
  } finally {
    await relay.close();
  }
});

test("an expired or reused pairing token is denied", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const token = routingToken(2);
    const host = await connectAuthed(relay.port, "host", { allowed: [] });
    host.ws.send(JSON.stringify({ type: "pair-token", token }));

    const dev1 = await connectAuthed(relay.port, "client", {});
    dev1.ws.send(JSON.stringify({ type: "pair", token, publicKey: b64(dev1.spki), name: "phone", proof: PROOF }));
    await next(host.ws, "pair-request"); // token consumed successfully once

    const dev2 = await connectAuthed(relay.port, "client", {});
    dev2.ws.send(JSON.stringify({ type: "pair", token, publicKey: b64(dev2.spki), name: "phone2", proof: PROOF }));
    const denied = await next(dev2.ws, "pair-denied");
    assert.equal(denied.reason, "token");

    // an unknown (but well-formed) token is denied the same way
    const dev3 = await connectAuthed(relay.port, "client", {});
    dev3.ws.send(JSON.stringify({
      type: "pair", token: routingToken(99), publicKey: b64(dev3.spki), name: "phone3", proof: PROOF,
    }));
    const denied2 = await next(dev3.ws, "pair-denied");
    assert.equal(denied2.reason, "token");
  } finally {
    await relay.close();
  }
});

// Security review C2: `pair.publicKey` was whatever the client typed, so a
// client could present somebody else's key and have the host prompted to
// trust a key whose owner never consumed the token. The relay now requires
// the key to be the one that signed its own auth challenge.
test("a pair whose publicKey is not the authed client's key closes the socket", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const token = routingToken(3);
    const host = await connectAuthed(relay.port, "host", { allowed: [] });
    host.ws.send(JSON.stringify({ type: "pair-token", token }));

    const dev = await connectAuthed(relay.port, "client", {});
    const other = await connectAuthed(relay.port, "client", {});
    dev.ws.once("error", () => {});

    let reachedHost = false;
    host.ws.on("message", (raw: Buffer) => {
      if (JSON.parse(raw.toString())?.type === "pair-request") reachedHost = true;
    });

    const closeCode = new Promise<number>((resolve) => dev.ws.once("close", resolve));
    // Somebody else's SPKI, on a socket authenticated as `dev`.
    dev.ws.send(JSON.stringify({
      type: "pair", token, publicKey: b64(other.spki), name: "phone", proof: PROOF,
    }));
    assert.equal(await closeCode, 4004);
    assert.equal(reachedHost, false, "a key-mismatched pair request must never reach the host");
  } finally {
    await relay.close();
  }
});
