import { webcrypto } from "node:crypto";
import { WebSocket } from "ws";

export function b64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64");
}
export function fromB64(s: string): Uint8Array {
  return new Uint8Array(Buffer.from(s, "base64"));
}

/**
 * A syntactically valid routing token: base64url of 16 bytes, 22 chars, no
 * padding -- the only shape the relay accepts since security review H1.
 * `seed` just makes distinct tokens readable in a failing test.
 */
export function routingToken(seed = 1): string {
  const bytes = new Uint8Array(16);
  for (let i = 0; i < bytes.length; i++) bytes[i] = (seed * 31 + i * 7) & 0xff;
  return Buffer.from(bytes).toString("base64url");
}

/** A stand-in for the device's HMAC pair proof; the relay carries it opaque. */
export const PROOF = b64(new Uint8Array(32).fill(7));

export interface AuthedPeer { ws: WebSocket; id: string; spki: Uint8Array }

/**
 * Opens a socket to the relay, completes the challenge/auth handshake with a
 * fresh ECDSA key pair, and resolves once the server has replied "authed".
 */
export async function connectAuthed(
  port: number,
  path: "host" | "client",
  extra: Record<string, unknown> = {}
): Promise<AuthedPeer> {
  const kp = await webcrypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = new Uint8Array(await webcrypto.subtle.exportKey("spki", kp.publicKey));
  const ws = new WebSocket(`ws://127.0.0.1:${port}/${path}`);
  const id = await new Promise<string>((resolve, reject) => {
    ws.once("error", reject);
    ws.once("message", (raw: Buffer) => {
      void (async () => {
        const challenge = JSON.parse(raw.toString());
        const nonce = fromB64(challenge.nonce);
        const signature = new Uint8Array(
          await webcrypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, kp.privateKey, nonce)
        );
        ws.once("message", (raw2: Buffer) => {
          const authed = JSON.parse(raw2.toString());
          resolve(authed.id);
        });
        ws.send(JSON.stringify({ type: "auth", publicKey: b64(spki), signature: b64(signature), ...extra }));
      })();
    });
  });
  return { ws, id, spki };
}

/** Resolves with the next JSON message of the given `type` received on `ws`. */
export function next(ws: WebSocket, type: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const onMessage = (raw: Buffer) => {
      let msg: any;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }
      if (msg?.type === type) {
        ws.off("message", onMessage);
        ws.off("error", onError);
        resolve(msg);
      }
    };
    const onError = (err: unknown) => {
      ws.off("message", onMessage);
      reject(err);
    };
    ws.on("message", onMessage);
    ws.once("error", onError);
  });
}
