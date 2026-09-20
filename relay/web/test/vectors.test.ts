import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { hkdfKeys, SessionKeys, pairProof, generateIdentity } from "../src/crypto.js";
import { embedVerdict, EMBED_BLOCKED_MESSAGE } from "../src/embed.js";
import { encodeMessage, decodeMessage, envelope, parseEnvelope } from "../src/codec.js";

// Cross-language pin (decision doc 2026-09-19): this vectors file is
// produced/consumed by three implementations (Swift host, Node relay tests,
// this web client). It is read from its one committed location, never
// copied, so a schedule change anywhere is caught here too.
//
// This runs from the compiled `dist/web/test/vectors.test.js`, which sits
// one directory deeper than the `web/test/` source tree (tsc's `outDir`
// nests everything under `relay/dist/`, mirroring `relay/`'s own layout) --
// hence four `../` rather than three to reach the repo root from here.
const vectorsUrl = new URL("../../../../Tests/vectors/remote-crypto-vectors.json", import.meta.url);
const vectors = JSON.parse(readFileSync(vectorsUrl, "utf8")) as {
  sharedSecretHex: string;
  hostId: string;
  deviceId: string;
  hostToClientKeyHex: string;
  clientToHostKeyHex: string;
  record0Hex: string;
  deviceSPKIHex: string;
  pairSecretHex: string;
  pairProofBase64: string;
};

function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}
function toHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

test("hkdfKeys reproduces the Swift-pinned key schedule", async () => {
  const sharedSecret = fromHex(vectors.sharedSecretHex);
  const { hostToClient, clientToHost } = await hkdfKeys(sharedSecret, vectors.hostId, vectors.deviceId);
  assert.equal(toHex(hostToClient), vectors.hostToClientKeyHex);
  assert.equal(toHex(clientToHost), vectors.clientToHostKeyHex);
});

// See crypto.ts's `bs` helper: @types/node's global Uint8Array override
// plus the DOM lib disagree on the ArrayBuffer type parameter, so a plain
// Uint8Array needs a narrowing cast to satisfy `BufferSource` here too.
function bs(bytes: Uint8Array): BufferSource {
  return bytes as unknown as BufferSource;
}

async function importAesGcmKey(raw: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", bs(raw), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

test("sealing \"hello\" at counter 0 under host->client matches the pinned record", async () => {
  const sharedSecret = fromHex(vectors.sharedSecretHex);
  const { hostToClient } = await hkdfKeys(sharedSecret, vectors.hostId, vectors.deviceId);
  const sendKey = await importAesGcmKey(hostToClient);
  const dummyRecvKey = await importAesGcmKey(hostToClient);
  const session = new SessionKeys(sendKey, dummyRecvKey);
  const record = await session.seal(new TextEncoder().encode("hello"));
  assert.equal(toHex(record), vectors.record0Hex);
});

test("opening the pinned record0 under host->client (as recv key) yields \"hello\", and a second open replays", async () => {
  const sharedSecret = fromHex(vectors.sharedSecretHex);
  const { hostToClient } = await hkdfKeys(sharedSecret, vectors.hostId, vectors.deviceId);
  const recvKey = await importAesGcmKey(hostToClient);
  const dummySendKey = await importAesGcmKey(hostToClient);
  const session = new SessionKeys(dummySendKey, recvKey);
  const record0 = fromHex(vectors.record0Hex);
  const plain = await session.open(record0);
  assert.equal(new TextDecoder().decode(plain), "hello");

  await assert.rejects(() => session.open(record0), /replay/);
});

test("open rejects malformed records (short, or bad tag) without advancing", async () => {
  const sharedSecret = fromHex(vectors.sharedSecretHex);
  const { hostToClient } = await hkdfKeys(sharedSecret, vectors.hostId, vectors.deviceId);
  const recvKey = await importAesGcmKey(hostToClient);
  const dummySendKey = await importAesGcmKey(hostToClient);
  const session = new SessionKeys(dummySendKey, recvKey);

  await assert.rejects(() => session.open(new Uint8Array(4)), /malformed/);

  const record0 = fromHex(vectors.record0Hex);
  const tampered = new Uint8Array(record0);
  tampered[tampered.length - 1] ^= 0xff;
  await assert.rejects(() => session.open(tampered), /malformed/);

  // The genuine record still opens afterwards -- neither failure advanced
  // the receive counter.
  const plain = await session.open(record0);
  assert.equal(new TextDecoder().decode(plain), "hello");
});

// -- Pairing proof (security review C2): the browser's half of the MAC
//    that binds this device's key to the QR code it scanned. The Swift
//    host recomputes it over the received SPKI before it will prompt, so
//    the two implementations are pinned to the same bytes here and in
//    Tests/MemtermCoreTests/RemoteCryptoTests.swift. --

test("pairProof reproduces the Swift-pinned pairing proof", async () => {
  const secret = fromHex(vectors.pairSecretHex);
  const spki = fromHex(vectors.deviceSPKIHex);
  assert.equal(secret.length, 16);
  assert.equal(await pairProof(secret, spki), vectors.pairProofBase64);
});

test("a pairProof is bound to one key and one secret", async () => {
  const secret = fromHex(vectors.pairSecretHex);
  const spki = fromHex(vectors.deviceSPKIHex);
  const proof = await pairProof(secret, spki);

  // A relay substituting its own key into a genuine request.
  const otherSpki = new Uint8Array(spki);
  otherSpki[otherSpki.length - 1] ^= 0xff;
  assert.notEqual(await pairProof(secret, otherSpki), proof);

  // A relay that never saw the secret half.
  const otherSecret = new Uint8Array(secret);
  otherSecret[0] ^= 0xff;
  assert.notEqual(await pairProof(otherSecret, spki), proof);
});

// -- Identity key storage (security review M4). --

test("the identity private key is non-extractable and still survives a structured clone", async () => {
  const identity = await generateIdentity();
  assert.equal(identity.privateKey.extractable, false);
  await assert.rejects(
    () => crypto.subtle.exportKey("pkcs8", identity.privateKey),
    "a non-extractable key must refuse to export"
  );
  // The public half stays exportable, which is how the SPKI above was
  // produced in the first place.
  assert.equal(identity.publicKeySPKI.length, 91);

  // IndexedDB stores the CryptoKey itself; that is the structured clone
  // algorithm, which carries non-extractable keys intact. Node's
  // structuredClone is the same algorithm, so this is the closest
  // headless proof that storing and re-reading the key still signs.
  const restored = structuredClone(identity);
  assert.equal(restored.privateKey.extractable, false);
  assert.equal(restored.id, identity.id);
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    restored.privateKey,
    bs(new TextEncoder().encode("nonce"))
  );
  assert.equal(signature.byteLength, 64);
  // And the proof path works off the restored identity's SPKI too.
  assert.equal(
    await pairProof(fromHex(vectors.pairSecretHex), restored.publicKeySPKI),
    await pairProof(fromHex(vectors.pairSecretHex), identity.publicKeySPKI)
  );
});

// -- Embedding (security re-review N2). --

test("the embed guard blocks a framed window and allows a top-level one", () => {
  const top = { self: {} } as { self: unknown; top: unknown };
  top.top = top.self; // a top-level document: window.top IS window.self
  assert.equal(embedVerdict(top), "ok");

  // Framed: `top` is the embedder's window, a different object.
  assert.equal(embedVerdict({ top: { embedder: true }, self: { page: true } }), "blocked");
  // Including the shapes a hostile embedder might hope pass: null, undefined
  // and a proxy that merely looks similar.
  assert.equal(embedVerdict({ top: null, self: { page: true } }), "blocked");
  assert.equal(embedVerdict({ top: undefined, self: { page: true } }), "blocked");
  assert.equal(embedVerdict({ top: { a: 1 }, self: { a: 1 } }), "blocked");

  assert.match(EMBED_BLOCKED_MESSAGE, /must not be embedded/);
});

// -- Codec: literal JSON fixtures pin the cross-language wire format. --

test("codec: attach round-trips through a literal JSON fixture", () => {
  const fixture = '{"t":"attach","paneId":"p1"}';
  const decoded = decodeMessage(fixture);
  assert.deepEqual(decoded, { t: "attach", paneId: "p1" });
  assert.equal(JSON.parse(encodeMessage(decoded!)).t, "attach");
  assert.equal(JSON.parse(encodeMessage(decoded!)).paneId, "p1");
});

test("codec: input round-trips bytes as base64 under \"b\"", () => {
  const fixture = '{"t":"input","b":"aGVsbG8="}'; // "hello"
  const decoded = decodeMessage(fixture);
  assert.ok(decoded && decoded.t === "input");
  assert.deepEqual(Array.from((decoded as { b: Uint8Array }).b), Array.from(new TextEncoder().encode("hello")));
  const reencoded = JSON.parse(encodeMessage(decoded!));
  assert.equal(reencoded.t, "input");
  assert.equal(reencoded.b, "aGVsbG8=");
});

test("codec: screen round-trips cols/rows/bytes", () => {
  const fixture = '{"t":"screen","cols":80,"rows":24,"b":"aGk="}'; // "hi"
  const decoded = decodeMessage(fixture);
  assert.ok(decoded && decoded.t === "screen");
  const screen = decoded as { t: "screen"; cols: number; rows: number; b: Uint8Array };
  assert.equal(screen.cols, 80);
  assert.equal(screen.rows, 24);
  assert.deepEqual(Array.from(screen.b), Array.from(new TextEncoder().encode("hi")));
  const reencoded = JSON.parse(encodeMessage(decoded!));
  assert.equal(reencoded.cols, 80);
  assert.equal(reencoded.rows, 24);
  assert.equal(reencoded.b, "aGk=");
});

test("codec: tree round-trips the full nested shape", () => {
  const fixture = JSON.stringify({
    t: "tree",
    tree: {
      workspaces: [
        {
          id: "w1",
          name: "Main",
          color: "#fff",
          locked: false,
          parked: true,
          windows: [
            {
              id: "win1",
              tabs: [
                {
                  id: "tab1",
                  title: "shell",
                  panes: [{ id: "p1", adapter: "pty", cwd: "/home" }, { id: "p2", adapter: "pty" }],
                },
              ],
            },
          ],
        },
      ],
    },
  });
  const decoded = decodeMessage(fixture);
  assert.deepEqual(decoded, JSON.parse(fixture));
  const reencoded = JSON.parse(encodeMessage(decoded!));
  assert.deepEqual(reencoded, JSON.parse(fixture));
});

test("codec: refused round-trips a reason", () => {
  const fixture = '{"t":"refused","reason":"locked"}';
  const decoded = decodeMessage(fixture);
  assert.deepEqual(decoded, { t: "refused", reason: "locked" });
  assert.deepEqual(JSON.parse(encodeMessage(decoded!)), { t: "refused", reason: "locked" });
});

test("codec: simple no-field tags decode and re-encode", () => {
  assert.deepEqual(decodeMessage('{"t":"list"}'), { t: "list" });
  assert.deepEqual(decodeMessage('{"t":"detach"}'), { t: "detach" });
  assert.deepEqual(decodeMessage('{"t":"tree-changed"}'), { t: "tree-changed" });
  assert.deepEqual(decodeMessage('{"t":"resize","cols":10,"rows":5}'), { t: "resize", cols: 10, rows: 5 });
  assert.deepEqual(decodeMessage('{"t":"resized","cols":10,"rows":5}'), { t: "resized", cols: 10, rows: 5 });
  assert.deepEqual(decodeMessage('{"t":"newTab","workspaceId":"w1"}'), { t: "newTab", workspaceId: "w1" });
  assert.deepEqual(decodeMessage('{"t":"unlock","workspaceId":"w1","passphrase":"secret"}'), {
    t: "unlock",
    workspaceId: "w1",
    passphrase: "secret",
  });
});

test("codec: decodeMessage never throws on garbage, returns undefined instead", () => {
  assert.equal(decodeMessage("not json"), undefined);
  assert.equal(decodeMessage("{}"), undefined);
  assert.equal(decodeMessage('{"t":"unknown-tag"}'), undefined);
  assert.equal(decodeMessage('{"t":"attach"}'), undefined); // missing paneId
  assert.equal(decodeMessage('{"t":"input","b":"not-valid-base64!!"}'), undefined);
  assert.equal(decodeMessage('{"t":"attach","paneId":123}'), undefined); // wrong type
  assert.equal(decodeMessage("null"), undefined);
  assert.equal(decodeMessage("[]"), undefined);
});

test("envelope/parseEnvelope round-trip the relay's outer JSON", () => {
  const payload = new TextEncoder().encode("sealed-bytes");
  const s = envelope("to-id", "from-id", payload);
  const parsed = JSON.parse(s);
  assert.equal(parsed.type, "env");
  assert.equal(parsed.to, "to-id");
  assert.equal(parsed.from, "from-id");

  const round = parseEnvelope(s);
  assert.ok(round);
  assert.equal(round!.to, "to-id");
  assert.equal(round!.from, "from-id");
  assert.deepEqual(Array.from(round!.payload), Array.from(payload));

  assert.equal(parseEnvelope("garbage"), undefined);
  assert.equal(parseEnvelope('{"type":"other"}'), undefined);
});
