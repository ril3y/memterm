export interface EnvMessage { type: "env"; to: string; from: string; payload: string }
export interface PairTokenMessage { type: "pair-token"; token: string }
export interface PairMessage { type: "pair"; token: string; publicKey: string; name: string }
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
      if (isString(msg.token)) {
        return { type: "pair-token", token: msg.token };
      }
      return undefined;
    case "pair":
      if (isString(msg.token) && isString(msg.publicKey) && isString(msg.name)) {
        return { type: "pair", token: msg.token, publicKey: msg.publicKey, name: msg.name };
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
