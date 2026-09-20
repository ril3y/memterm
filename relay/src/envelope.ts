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
 * Validates a parsed JSON value against the relay's post-auth message shapes.
 * Returns undefined for anything that doesn't match exactly one of them,
 * including an unrecognized `type` or a known `type` with malformed fields.
 */
export function parseInbound(value: unknown): InboundMessage | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const msg = value as Record<string, unknown>;

  switch (msg.type) {
    case "env":
      if (isString(msg.to) && isString(msg.from) && isString(msg.payload)) {
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
        return { type: "pair", token: msg.token, publicKey: msg.publicKey, name: msg.name, proof: msg.proof };
      }
      return undefined;
    case "pair-answer":
      if (isString(msg.deviceId) && typeof msg.accept === "boolean") {
        return { type: "pair-answer", deviceId: msg.deviceId, accept: msg.accept };
      }
      return undefined;
    case "allowed":
      if (Array.isArray(msg.devices) && msg.devices.every(isString)) {
        return { type: "allowed", devices: msg.devices };
      }
      return undefined;
    default:
      return undefined;
  }
}
