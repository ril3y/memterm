export interface EnvMessage { type: "env"; to: string; from: string; payload: string }
export interface PairTokenMessage { type: "pair-token"; token: string }
export interface PairMessage { type: "pair"; token: string; publicKey: string; name: string; proof: string }
export interface PairAnswerMessage { type: "pair-answer"; deviceId: string; accept: boolean }
export interface AllowedMessage { type: "allowed"; devices: string[] }

export type InboundMessage =
  | EnvMessage
  | PairTokenMessage
  | PairMessage
  | PairAnswerMessage
  | AllowedMessage;

function isString(v: unknown): v is string {
  return typeof v === "string";
}

/**
 * A routing token is base64url of exactly 16 bytes: 22 characters, no
 * padding, from the alphabet RFC 4648 §5 defines. The host mints it that
 * way (`RemotePairing.split` in MemtermCore) and the relay only ever uses
 * it as a map key.
 *
 * Validating the shape here is a memory bound, not a crypto check
 * (security review H1): `token` was an arbitrary string with no length
 * limit, so one authenticated socket could loop `pair-token` with 1 MiB
 * tokens and fill a 512 MB machine in seconds. A fixed 22 characters means
 * a pairing entry costs a known, tiny amount.
 */
const ROUTING_TOKEN = /^[A-Za-z0-9_-]{22}$/;

export function isRoutingToken(v: unknown): v is string {
  return typeof v === "string" && ROUTING_TOKEN.test(v);
}

/**
 * A peer id is `base32(SHA-256(spki))[0..16]` in the lower-case RFC 4648
 * alphabet (`auth.ts`), so it is always exactly 16 characters of
 * `[a-z2-7]`. The relay computes every id it TRUSTS that way; these are
 * the ones it merely carries.
 *
 * Bounding them is the second half of the memory fix (security re-review
 * N3): entry COUNTS were capped at 64 but each string was unbounded, so
 * inside the 1 MiB frame limit a host could announce 64 ids of ~16 KB and
 * have them retained in both `allowed` and `watchers` — roughly 2 MiB held
 * per host socket, with nothing to stop a fleet of them.
 *
 * A non-conforming id can never match a real authenticated peer anyway, so
 * refusing it costs nothing real.
 */
const PEER_ID = /^[a-z2-7]{16}$/;

export function isPeerId(v: unknown): v is string {
  return typeof v === "string" && PEER_ID.test(v);
}

/**
 * Keeps only well-formed ids from a list a peer announced.
 *
 * Lists are FILTERED where single-id fields are rejected outright: an
 * allow-list is a host's whole set of devices, and dropping the entire
 * message (closing the socket) over one malformed entry would revoke every
 * real device it named. Filtering loses nothing, because an id that is not
 * 16 base32 characters cannot be any peer's id.
 */
export function peerIds(values: unknown[]): string[] {
  return values.filter(isPeerId);
}

/** The longest device name the relay will carry, in BYTES of UTF-8. */
export const MAX_NAME_BYTES = 64;

/**
 * Caps a device name before it is forwarded (security re-review N3). The
 * host sanitizes and shortens it again to 32 characters for the prompt;
 * this is purely so the relay never holds or forwards a megabyte of it.
 *
 * Cutting UTF-8 at a byte boundary can split a code point, which decodes
 * to a trailing replacement character — trimmed here so a truncated name
 * does not end in visible garbage.
 */
export function capName(name: string): string {
  const bytes = Buffer.from(name, "utf8");
  if (bytes.length <= MAX_NAME_BYTES) return name;
  return bytes.subarray(0, MAX_NAME_BYTES).toString("utf8").replace(/�+$/, "");
}

/**
 * Validates a parsed JSON value against the relay's post-auth message shapes.
 * Returns undefined for anything that doesn't match exactly one of them,
 * including an unrecognized `type` or a known `type` with malformed fields.
 */
export function parseInbound(value: unknown): InboundMessage | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const msg = value as Record<string, unknown>;

  switch (msg.type) {
    case "env":
      // `to` and `from` address peers, so they must be peer ids. A single
      // malformed one is refused rather than filtered: there is nothing
      // left of the message without it.
      if (isPeerId(msg.to) && isPeerId(msg.from) && isString(msg.payload)) {
        return { type: "env", to: msg.to, from: msg.from, payload: msg.payload };
      }
      return undefined;
    case "pair-token":
      if (isRoutingToken(msg.token)) {
        return { type: "pair-token", token: msg.token };
      }
      return undefined;
    case "pair":
      // `proof` is required: a device that cannot prove it scanned the QR
      // code has nothing to forward (security review C2). The relay never
      // checks it -- it cannot, it has no secret -- it only refuses to
      // carry a request that is missing one.
      if (isRoutingToken(msg.token) && isString(msg.publicKey) && isString(msg.name) && isString(msg.proof)) {
        return {
          type: "pair", token: msg.token, publicKey: msg.publicKey,
          name: capName(msg.name), proof: msg.proof,
        };
      }
      return undefined;
    case "pair-answer":
      if (isPeerId(msg.deviceId) && typeof msg.accept === "boolean") {
        return { type: "pair-answer", deviceId: msg.deviceId, accept: msg.accept };
      }
      return undefined;
    case "allowed":
      if (Array.isArray(msg.devices)) {
        return { type: "allowed", devices: peerIds(msg.devices) };
      }
      return undefined;
    default:
      return undefined;
  }
}
