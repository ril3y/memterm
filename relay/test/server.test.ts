import { test } from "node:test";
import assert from "node:assert/strict";
import { startRelay } from "../src/server.js";

test("healthz answers ok and the web root is served", async () => {
  const relay = await startRelay({ port: 0, webRoot: new URL("../web", import.meta.url).pathname });
  const health = await fetch(`http://127.0.0.1:${relay.port}/healthz`);
  assert.equal(health.status, 200);
  assert.equal(await health.text(), "ok");
  const index = await fetch(`http://127.0.0.1:${relay.port}/`);
  assert.equal(index.status, 200);
  assert.match(await index.text(), /memterm/);
  await relay.close();
});
