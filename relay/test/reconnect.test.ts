// Field bug 2026-09-22 ("click a pane, type a letter, kicked out, then
// nothing"): a peer that reconnects registers its new socket first, and the
// OLD socket's close event can land afterwards. The relay used to delete
// whatever was registered under that id on any close, so the fresh socket
// vanished from the map: the host believed it was connected, and every
// envelope for it was refused or dropped.
import { test } from "node:test";
import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import path from "node:path";
import { startRelay } from "../src/server.js";
import { connectAuthed, connectAuthedAs, next } from "./helpers.js";

const WEB = path.resolve(process.cwd(), "web");

function closed(ws: import("ws").WebSocket): Promise<void> {
  return new Promise((resolve) => {
    if (ws.readyState === ws.CLOSED) { resolve(); return; }
    ws.once("close", () => resolve());
  });
}

/** Resolves true if a message of `type` arrives within `ms`, false otherwise. */
function arrivesWithin(ws: import("ws").WebSocket, type: string, ms: number): Promise<boolean> {
  return Promise.race([
    next(ws, type).then(() => true),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), ms)),
  ]);
}

test("a host's replaced socket closing does not drop its fresh registration", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const dev = await connectAuthed(relay.port, "client", {});
    const kp = await webcrypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const first = await connectAuthedAs(relay.port, "host", kp, { allowed: [dev.id] });

    // Reconnect: the same host id on a new socket. The relay closes the
    // old socket itself; its close event is the one that used to wipe us.
    const second = await connectAuthedAs(relay.port, "host", kp, { allowed: [dev.id] });
    assert.equal(second.id, first.id);
    await closed(first.ws);

    // The stale close must not have announced the host as offline...
    assert.equal(await arrivesWithin(dev.ws, "offline", 300), false);

    // ...and the host must still be routable on its new socket.
    dev.ws.send(JSON.stringify({ type: "env", to: second.id, from: dev.id, payload: "AQID" }));
    const env = await next(second.ws, "env");
    assert.equal(env.from, dev.id);
    assert.equal(env.payload, "AQID");
  } finally {
    await relay.close();
  }
});

test("a client's replaced socket closing does not drop its fresh registration", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const kp = await webcrypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const firstDev = await connectAuthedAs(relay.port, "client", kp, {});
    const host = await connectAuthed(relay.port, "host", { allowed: [firstDev.id] });

    const secondDev = await connectAuthedAs(relay.port, "client", kp, {});
    assert.equal(secondDev.id, firstDev.id);
    await closed(firstDev.ws);

    host.ws.send(JSON.stringify({ type: "env", to: secondDev.id, from: host.id, payload: "AQID" }));
    const env = await next(secondDev.ws, "env");
    assert.equal(env.from, host.id);
  } finally {
    await relay.close();
  }
});

test("a genuine host close still announces offline", async () => {
  const relay = await startRelay({ port: 0, webRoot: WEB });
  try {
    const dev = await connectAuthed(relay.port, "client", {});
    const host = await connectAuthed(relay.port, "host", { allowed: [dev.id] });
    host.ws.close();
    const offline = await next(dev.ws, "offline");
    assert.equal(offline.hostId, host.id);
  } finally {
    await relay.close();
  }
});
