import { test } from "node:test";
import assert from "node:assert/strict";
import { startRelay } from "../src/server.js";
import { connectAuthed, next, b64 } from "./helpers.js";

const WEB = new URL("../web", import.meta.url).pathname;

test("pairing, forwarding both ways, host-drop -> offline, revocation", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const host = await connectAuthed(relay.port, "host", { allowed: [] });
    host.ws.send(JSON.stringify({ type: "pair-token", token: "T1" }));

    const dev = await connectAuthed(relay.port, "client", {});
    dev.ws.send(JSON.stringify({ type: "pair", token: "T1", publicKey: b64(dev.spki), name: "phone" }));

    const req = await next(host.ws, "pair-request");
    assert.equal(req.deviceId, dev.id);
    assert.equal(req.publicKey, b64(dev.spki));
    assert.equal(req.name, "phone");

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
    const host = await connectAuthed(relay.port, "host", { allowed: [] });
    host.ws.send(JSON.stringify({ type: "pair-token", token: "T2" }));

    const dev1 = await connectAuthed(relay.port, "client", {});
    dev1.ws.send(JSON.stringify({ type: "pair", token: "T2", publicKey: b64(dev1.spki), name: "phone" }));
    await next(host.ws, "pair-request"); // token consumed successfully once

    const dev2 = await connectAuthed(relay.port, "client", {});
    dev2.ws.send(JSON.stringify({ type: "pair", token: "T2", publicKey: b64(dev2.spki), name: "phone2" }));
    const denied = await next(dev2.ws, "pair-denied");
    assert.equal(denied.reason, "token");

    // an unknown token is denied the same way
    const dev3 = await connectAuthed(relay.port, "client", {});
    dev3.ws.send(JSON.stringify({ type: "pair", token: "never-issued", publicKey: b64(dev3.spki), name: "phone3" }));
    const denied2 = await next(dev3.ws, "pair-denied");
    assert.equal(denied2.reason, "token");
  } finally {
    await relay.close();
  }
});
