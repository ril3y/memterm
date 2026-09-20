// Relay socket for the web client (decision doc 2026-09-19): the `/client`
// WebSocket, its auth handshake, envelope send/receive, and reconnect with
// backoff. Matches `relay/src/server.ts` exactly -- see the comments there
// for the wire shapes this file produces and consumes.

import type { Identity } from "./crypto.js";
import { signNonce } from "./crypto.js";
import { envelope, parseEnvelope } from "./codec.js";

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

function fromBase64(s: string): Uint8Array | undefined {
  try {
    const binary = atob(s);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
    return out;
  } catch {
    return undefined;
  }
}

export interface RelayEvents {
  /** The relay accepted our auth signature; `id` is our own id (derived from our SPKI). */
  onAuthed?: (id: string) => void;
  onPaired?: (hostId: string, hostPublicKey: string) => void;
  onPairDenied?: (reason: string) => void;
  onOnline?: (hostId: string) => void;
  onOffline?: (hostId: string, lastSeenMs: number) => void;
  /** A relay-level routing failure for an envelope we sent. One reason,
   *  `not-allowed`, covers both "not connected" and "not permitted": the
   *  relay deliberately does not say which (security review L2). */
  onRefused?: (reason: string) => void;
  onEnvelope?: (from: string, payload: Uint8Array) => void;
  /** The socket dropped (initial connect failure or a later close); a reconnect is already scheduled. */
  onDisconnected?: () => void;
}

const MIN_BACKOFF_MS = 1000;
const MAX_BACKOFF_MS = 30_000;

/**
 * One logical connection to the relay's `/client` endpoint. Handles the
 * challenge/auth handshake on every (re)connect and reconnects on close with
 * exponential backoff, 1s -> 30s. `connect`/`close` are the only lifecycle
 * calls; everything else is fire-and-forget sends plus the `RelayEvents`
 * callbacks.
 */
export class RelayClient {
  private ws: WebSocket | undefined;
  private closedByCaller = false;
  private backoffMs = MIN_BACKOFF_MS;
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined;

  constructor(
    private readonly relayWsUrl: string,
    private readonly identity: Identity,
    private readonly events: RelayEvents
  ) {}

  connect(): void {
    this.closedByCaller = false;
    this.open();
  }

  close(): void {
    this.closedByCaller = true;
    if (this.reconnectTimer !== undefined) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = undefined;
    }
    this.ws?.close();
    this.ws = undefined;
  }

  /**
   * `proof` is `HMAC(secret half of the QR token, label ‖ our SPKI)` --
   * see `crypto.ts`'s `pairProof`. The relay forwards it untouched; only
   * the host can check it, and it refuses to prompt without one (security
   * review C2).
   */
  pair(token: string, name: string, proof: string): void {
    this.send({ type: "pair", token, publicKey: toBase64(this.identity.publicKeySPKI), name, proof });
  }

  sendEnvelope(to: string, payload: Uint8Array): void {
    this.raw(envelope(to, this.identity.id, payload));
  }

  private open(): void {
    // Never let a stray reconnect stack a second live socket on top of one
    // that is still connecting/open.
    if (this.ws && this.ws.readyState !== WebSocket.CLOSED) return;
    const ws = new WebSocket(`${this.relayWsUrl.replace(/\/+$/, "")}/client`);
    this.ws = ws;
    ws.addEventListener("message", (ev) => {
      void this.handleMessage(String(ev.data));
    });
    ws.addEventListener("close", () => {
      if (this.ws === ws) this.ws = undefined;
      this.events.onDisconnected?.();
      if (!this.closedByCaller) this.scheduleReconnect();
    });
    ws.addEventListener("error", () => ws.close());
  }

  private scheduleReconnect(): void {
    if (this.reconnectTimer !== undefined) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = undefined;
      this.open();
    }, this.backoffMs);
    this.backoffMs = Math.min(this.backoffMs * 2, MAX_BACKOFF_MS);
  }

  private async handleMessage(raw: string): Promise<void> {
    const env = parseEnvelope(raw);
    if (env) {
      this.events.onEnvelope?.(env.from, env.payload);
      return;
    }
    let value: unknown;
    try {
      value = JSON.parse(raw);
    } catch {
      return;
    }
    if (typeof value !== "object" || value === null) return;
    const msg = value as Record<string, unknown>;
    switch (msg.type) {
      case "challenge": {
        if (typeof msg.nonce !== "string") return;
        const nonce = fromBase64(msg.nonce);
        if (!nonce) return;
        const signature = await signNonce(this.identity.privateKey, nonce);
        this.send({ type: "auth", publicKey: toBase64(this.identity.publicKeySPKI), signature: toBase64(signature) });
        return;
      }
      case "authed":
        this.backoffMs = MIN_BACKOFF_MS;
        if (typeof msg.id === "string") this.events.onAuthed?.(msg.id);
        return;
      case "paired":
        if (typeof msg.hostId === "string" && typeof msg.hostPublicKey === "string") {
          this.events.onPaired?.(msg.hostId, msg.hostPublicKey);
        }
        return;
      case "pair-denied":
        this.events.onPairDenied?.(typeof msg.reason === "string" ? msg.reason : "denied");
        return;
      case "online":
        if (typeof msg.hostId === "string") this.events.onOnline?.(msg.hostId);
        return;
      case "offline":
        if (typeof msg.hostId === "string" && typeof msg.lastSeen === "number") {
          this.events.onOffline?.(msg.hostId, msg.lastSeen);
        }
        return;
      case "refused":
        this.events.onRefused?.(typeof msg.reason === "string" ? msg.reason : "refused");
        return;
    }
  }

  private send(obj: unknown): void {
    this.raw(JSON.stringify(obj));
  }

  private raw(data: string): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(data);
  }
}
