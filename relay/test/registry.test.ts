import { test } from "node:test";
import assert from "node:assert/strict";
import { Registry } from "../src/registry.js";

const sock = () => ({ send() {}, close() {} }) as any;

test("pairing tokens are single-use and expire", () => {
  const r = new Registry();
  r.createPairing("h1", "tok", 120_000, 1_000);
  assert.equal(r.consumePairing("tok", 60_000)?.hostId, "h1");
  assert.equal(r.consumePairing("tok", 60_000), undefined);        // single use
  r.createPairing("h1", "tok2", 120_000, 1_000);
  assert.equal(r.consumePairing("tok2", 200_000), undefined);      // expired
});

test("hosts carry an allow-list; clients are looked up by device id", () => {
  const r = new Registry();
  r.registerHost("h1", sock(), new Set(["dA"]));
  r.registerClient("dA", sock());
  assert.ok(r.host("h1")!.allowed.has("dA"));
  assert.ok(r.client("dA"));
  r.unregisterHost("h1");
  assert.equal(r.host("h1"), undefined);
});
