import { idFromPublicKey } from "../../src/auth.js";

// Remote-attach web client crypto (decision doc 2026-09-19). This is the
// phone browser's half of the handshake and record protocol whose Swift
// host side lives in `Sources/MemtermCore/Remote/RemoteCrypto.swift`; every
// byte format here is a wire contract with that file and with the relay
// (`relay/src/auth.ts`), not an implementation detail. `Tests/vectors/
// remote-crypto-vectors.json` pins the key schedule and the first record;
// `relay/web/test/vectors.test.ts` reads that same committed file.
//
// crypto.subtle behaves identically in Node 20 (globalThis.crypto) and in
// browsers, so this file uses only that -- no third-party crypto, and no
// `node:crypto` import (which would type-check against a different, looser
// surface than the one the browser actually has).

// TypeScript (with @types/node's global Uint8Array override alongside the
// DOM lib) infers plain `new Uint8Array(n)` as `Uint8Array<ArrayBufferLike>`,
// which the DOM `BufferSource` parameter type of `SubtleCrypto` methods
// rejects at the type level even though the runtime value is fine in both
// Node and every browser. This narrows just enough to satisfy the compiler
// at each call site.
function bs(bytes: Uint8Array): BufferSource {
  return bytes as unknown as BufferSource;
}

function utf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

function concatBytes(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

// Portable base64: `Buffer` in Node, `btoa`/`atob` in the browser. Both
// globals are declared here (Node types + DOM lib), so this compiles as
// written and picks the one that actually exists at runtime.
function toBase64(bytes: Uint8Array): string {
  if (typeof Buffer !== "undefined") return Buffer.from(bytes).toString("base64");
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function fromBase64(s: string): Uint8Array {
  if (typeof Buffer !== "undefined") return new Uint8Array(Buffer.from(s, "base64"));
  const binary = atob(s);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

// -- Identity: ECDSA P-256, signed against the relay's auth challenge. --

export interface Identity {
  privateKey: CryptoKey;
  publicKeySPKI: Uint8Array;
  id: string;
}

/**
 * Generates a fresh long-lived identity key pair and its relay-facing id.
 *
 * NON-EXTRACTABLE (security review M4): the private key is generated with
 * `extractable: false`, so `exportKey`/`wrapKey` refuse it and any script
 * that runs on this origin can sign with the key only while it is running
 * -- it cannot walk away with a copy and impersonate this device forever
 * after the tab is closed and the bug fixed. Nothing is lost: the key is
 * only ever used to sign, the CryptoKey survives IndexedDB (structured
 * clone carries non-extractable keys), and WebCrypto always leaves the
 * PUBLIC half of a generated pair extractable, so the SPKI export below
 * still works.
 */
export async function generateIdentity(): Promise<Identity> {
  const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
  const publicKeySPKI = new Uint8Array(await crypto.subtle.exportKey("spki", keyPair.publicKey));
  const id = await idFromPublicKey(publicKeySPKI);
  return { privateKey: keyPair.privateKey, publicKeySPKI, id };
}

// -- Pairing proof: this device really did scan that QR code. --

/**
 * Domain separation, identical to the Swift host's
 * `RemotePairing.proofLabel`.
 */
export const PAIR_PROOF_LABEL = "memterm-remote-v1:pair";

/**
 * `HMAC-SHA256(secret, PAIR_PROOF_LABEL ‖ deviceSPKI)`, base64 (standard,
 * like every other key/signature field on this wire).
 *
 * Security review C2: the QR code's token is split in two. The relay gets
 * the routing half and uses it as a map key; `secret` is the other half,
 * which only ever exists in the QR code and in the host's pending
 * pairing. Sending this MAC alongside our public key proves to the host
 * that the key it is about to trust belongs to whoever actually scanned
 * the code -- so a hostile relay can neither substitute its own key into
 * a genuine request nor invent a request of its own.
 */
export async function pairProof(secret: Uint8Array, deviceSPKI: Uint8Array): Promise<string> {
  const key = await crypto.subtle.importKey("raw", bs(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, bs(concatBytes(utf8(PAIR_PROOF_LABEL), deviceSPKI)));
  return toBase64(new Uint8Array(mac));
}

/**
 * Signs the relay's 32-byte auth nonce. WebCrypto's ECDSA signature is
 * already raw r‖s (64 bytes for P-256) -- the format the relay verifies.
 */
export async function signNonce(privateKey: CryptoKey, nonce: Uint8Array): Promise<Uint8Array> {
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, privateKey, bs(nonce));
  return new Uint8Array(sig);
}

// -- Handshake: ephemeral ECDH offer, signed by the identity key. --

/** Domain separation, identical to the Swift host's `helloSigningLabel`. */
export const HELLO_SIGNING_LABEL = "memterm-remote-v1:hello";

export interface Hello {
  /** The ephemeral P-256 public key, raw uncompressed point, base64. */
  ephemeralRaw: string;
  /** Raw r‖s over `HELLO_SIGNING_LABEL ‖ ephemeralRaw`, base64. */
  signature: string;
}

function helloSigningPayload(ephemeralRawBytes: Uint8Array): Uint8Array {
  return concatBytes(utf8(HELLO_SIGNING_LABEL), ephemeralRawBytes);
}

/** Generates a fresh ephemeral ECDH key and a Hello offering it, signed by `identityPrivateKey`. */
export async function makeHello(identityPrivateKey: CryptoKey): Promise<{ hello: Hello; ephemeralPrivate: CryptoKey }> {
  const ephemeral = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const ephemeralRawBytes = new Uint8Array(await crypto.subtle.exportKey("raw", ephemeral.publicKey));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    identityPrivateKey,
    bs(helloSigningPayload(ephemeralRawBytes))
  );
  return {
    hello: { ephemeralRaw: toBase64(ephemeralRawBytes), signature: toBase64(new Uint8Array(signature)) },
    ephemeralPrivate: ephemeral.privateKey,
  };
}

/**
 * Verifies a Hello was signed by the identity behind `peerSPKI`. Both
 * arguments come off the wire, so any parse failure (bad SPKI shape,
 * unparseable base64/signature) is just "not verified", never a throw.
 */
export async function verifyHello(hello: Hello, peerSPKI: Uint8Array): Promise<boolean> {
  try {
    const peerKey = await crypto.subtle.importKey("spki", bs(peerSPKI), { name: "ECDSA", namedCurve: "P-256" }, false, [
      "verify",
    ]);
    const ephemeralRawBytes = fromBase64(hello.ephemeralRaw);
    const signatureBytes = fromBase64(hello.signature);
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      peerKey,
      bs(signatureBytes),
      bs(helloSigningPayload(ephemeralRawBytes))
    );
  } catch {
    return false;
  }
}

/** Wire encoding for a Hello: UTF-8 JSON `{"hs":"hello","eph":...,"sig":...}`. */
export function encodeHello(hello: Hello): string {
  return JSON.stringify({ hs: "hello", eph: hello.ephemeralRaw, sig: hello.signature });
}

/** Decodes a Hello, or `undefined` on anything that isn't exactly that shape. Never throws. */
export function decodeHello(s: string): Hello | undefined {
  try {
    const value: unknown = JSON.parse(s);
    if (typeof value !== "object" || value === null) return undefined;
    const obj = value as Record<string, unknown>;
    if (obj.hs !== "hello" || typeof obj.eph !== "string" || typeof obj.sig !== "string") return undefined;
    return { ephemeralRaw: obj.eph, signature: obj.sig };
  } catch {
    return undefined;
  }
}

// -- Key schedule: one HKDF-SHA256 expansion, split by direction. --

export interface DirectionalKeys {
  hostToClient: Uint8Array;
  clientToHost: Uint8Array;
}

/**
 * The key schedule on its own (no ECDH), so the shared vectors can pin it:
 * `okm = HKDF-SHA256(ikm = sharedSecret, salt = "", info = "memterm-remote-v1" ‖ hostId ‖ deviceId, 64 bytes)`,
 * split into host→client = okm[0..32) and client→host = okm[32..64).
 */
export async function hkdfKeys(sharedSecret: Uint8Array, hostId: string, deviceId: string): Promise<DirectionalKeys> {
  const ikm = await crypto.subtle.importKey("raw", bs(sharedSecret), "HKDF", false, ["deriveBits"]);
  const info = concatBytes(utf8("memterm-remote-v1"), utf8(hostId), utf8(deviceId));
  const okm = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt: bs(new Uint8Array(0)), info: bs(info) },
      ikm,
      64 * 8
    )
  );
  return { hostToClient: okm.slice(0, 32), clientToHost: okm.slice(32, 64) };
}

async function importAesGcmKey(raw: Uint8Array): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", bs(raw), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

/**
 * Runs the ECDH agreement and the key schedule, returning ready-to-use
 * AES-GCM keys for this side of the connection.
 *
 * - Warning: `hostId` and `deviceId` bind the session to two already-verified
 *   identities. Only pass ids computed from SPKIs that have already passed
 *   `verifyHello` (your own identity, and the peer's) -- never an id taken
 *   from a field on the wire, which an attacker could choose freely and
 *   which would silently remove that binding.
 */
export async function deriveKeys(
  myEphemeralPrivate: CryptoKey,
  peerEphemeralRaw: Uint8Array,
  hostId: string,
  deviceId: string,
  iAmHost = false
): Promise<{ sendKey: CryptoKey; recvKey: CryptoKey }> {
  const peerKey = await crypto.subtle.importKey("raw", bs(peerEphemeralRaw), { name: "ECDH", namedCurve: "P-256" }, false, []);
  const sharedSecret = new Uint8Array(
    await crypto.subtle.deriveBits({ name: "ECDH", public: peerKey }, myEphemeralPrivate, 256)
  );
  const { hostToClient, clientToHost } = await hkdfKeys(sharedSecret, hostId, deviceId);
  const hostToClientKey = await importAesGcmKey(hostToClient);
  const clientToHostKey = await importAesGcmKey(clientToHost);
  return iAmHost
    ? { sendKey: hostToClientKey, recvKey: clientToHostKey }
    : { sendKey: clientToHostKey, recvKey: hostToClientKey };
}

// -- Records: AES-256-GCM, big-endian counter nonce per direction. --

function nonceBytes(counter: bigint): Uint8Array {
  const out = new Uint8Array(12);
  const view = new DataView(out.buffer);
  view.setBigUint64(4, counter, false);
  return out;
}

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/**
 * One direction-split AES-256-GCM session. The counters are the replay
 * defence: `open` accepts only the next counter this direction expects, and
 * neither a replay nor a bad tag advances it -- the genuine next record
 * still opens afterwards.
 */
export class SessionKeys {
  private readonly sendKey: CryptoKey;
  private readonly recvKey: CryptoKey;
  private sendCounter = 0n;
  private recvCounter = 0n;

  constructor(sendKey: CryptoKey, recvKey: CryptoKey) {
    this.sendKey = sendKey;
    this.recvKey = recvKey;
  }

  /** Record = nonce (12) ‖ ciphertext ‖ tag (16); WebCrypto's `encrypt` output is already ciphertext‖tag. */
  async seal(plain: Uint8Array): Promise<Uint8Array> {
    const nonce = nonceBytes(this.sendCounter);
    const sealed = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv: bs(nonce) }, this.sendKey, bs(plain)));
    this.sendCounter += 1n;
    const out = new Uint8Array(nonce.length + sealed.length);
    out.set(nonce, 0);
    out.set(sealed, nonce.length);
    return out;
  }

  /**
   * Requires the record's nonce to equal the next expected counter, else
   * throws `Error("replay")` without advancing. A wrong length or a failed
   * GCM tag throws `Error("malformed")`, also without advancing.
   */
  async open(record: Uint8Array): Promise<Uint8Array> {
    if (record.length < 12 + 16) throw new Error("malformed");
    const recordNonce = record.slice(0, 12);
    if (!bytesEqual(recordNonce, nonceBytes(this.recvCounter))) throw new Error("replay");
    let plain: Uint8Array;
    try {
      plain = new Uint8Array(
        await crypto.subtle.decrypt({ name: "AES-GCM", iv: bs(recordNonce) }, this.recvKey, bs(record.slice(12)))
      );
    } catch {
      throw new Error("malformed");
    }
    this.recvCounter += 1n;
    return plain;
  }
}
