export interface PeerSocket { send(data: string): void; close(code?: number, reason?: string): void }
export interface HostEntry { socket: PeerSocket; allowed: Set<string>; publicKey: string }
export interface ClientEntry { socket: PeerSocket }

/**
 * Memory bounds (security review H1). Authenticating as a host costs an
 * attacker nothing -- generate a P-256 key, sign the challenge -- and every
 * map below was previously unbounded, so a single socket could fill the
 * 512 MB Fly machine at will. Each cap is deliberately far above anything a
 * real host does: two pairings is one QR sheet plus a retry, 64 devices is
 * more phones than anyone owns, and a day of `lastSeenAt` is all the
 * "offline since" line ever reads.
 */
export const MAX_PAIRINGS_PER_HOST = 2;
export const MAX_ALLOWED_DEVICES = 64;
export const LAST_SEEN_TTL_MS = 24 * 60 * 60 * 1000;

export class Registry {
  private hosts = new Map<string, HostEntry>();
  private clients = new Map<string, ClientEntry>();
  private pairings = new Map<string, { hostId: string; expiresAt: number; createdAt: number }>();
  private lastSeenAt = new Map<string, number>();
  // Devices that have ever paired with a host, for presence (online/offline) fan-out.
  // Deliberately separate from HostEntry.allowed: revocation removes forwarding
  // rights immediately but a revoked device should still learn the host went offline.
  private watchers = new Map<string, Set<string>>();
  registerHost(hostId: string, socket: PeerSocket, allowed: Set<string>, publicKey = "") {
    this.hosts.set(hostId, { socket, allowed: capSet(allowed), publicKey });
    const watching = this.watchers.get(hostId) ?? new Set<string>();
    for (const deviceId of allowed) watching.add(deviceId);
    this.watchers.set(hostId, capSet(watching));
  }
  unregisterHost(hostId: string) { this.hosts.delete(hostId); this.watchers.delete(hostId); }
  host(hostId: string) { return this.hosts.get(hostId); }
  registerClient(deviceId: string, socket: PeerSocket) { this.clients.set(deviceId, { socket }); }
  unregisterClient(deviceId: string) { this.clients.delete(deviceId); }
  client(deviceId: string) { return this.clients.get(deviceId); }
  /** Marks deviceId as paired with hostId for presence purposes (see `watchers` above). */
  addWatcher(hostId: string, deviceId: string) {
    const watching = this.watchers.get(hostId) ?? new Set<string>();
    watching.add(deviceId);
    this.watchers.set(hostId, capSet(watching));
  }
  /** Connected clients that should be told about hostId's presence (online/offline). */
  clientsAllowedBy(hostId: string): ClientEntry[] {
    const watching = this.watchers.get(hostId);
    if (!watching) return [];
    const out: ClientEntry[] = [];
    for (const deviceId of watching) {
      const client = this.clients.get(deviceId);
      if (client) out.push(client);
    }
    return out;
  }
  markSeen(hostId: string, now: number) { this.lastSeenAt.set(hostId, now); }
  lastSeen(hostId: string): number | undefined { return this.lastSeenAt.get(hostId); }
  /**
   * Registers a pairing token. Every insert first sweeps expired pairings
   * and stale `lastSeenAt` rows, then holds the per-host cap by dropping
   * that host's OLDEST pairing -- so a host loops in place instead of
   * accumulating.
   *
   * This is not the only sweep site: host auth sweeps too (`server.ts`),
   * because a throwaway host id adds a `lastSeenAt` row without ever
   * pairing.
   */
  createPairing(hostId: string, token: string, ttlMs: number, now: number) {
    this.sweep(now);
    const mine = [...this.pairings.entries()]
      .filter(([, p]) => p.hostId === hostId)
      .sort((a, b) => a[1].createdAt - b[1].createdAt);
    for (let i = 0; i <= mine.length - MAX_PAIRINGS_PER_HOST; i++) this.pairings.delete(mine[i][0]);
    this.pairings.set(token, { hostId, expiresAt: now + ttlMs, createdAt: now });
  }
  consumePairing(token: string, now: number) {
    const p = this.pairings.get(token); if (!p) return undefined;
    this.pairings.delete(token);
    return now <= p.expiresAt ? { hostId: p.hostId } : undefined;
  }
  /** Drops every expired pairing and every `lastSeenAt` row older than a day. */
  sweep(now: number) {
    for (const [token, p] of this.pairings) if (now > p.expiresAt) this.pairings.delete(token);
    for (const [hostId, seen] of this.lastSeenAt) {
      if (now - seen > LAST_SEEN_TTL_MS) this.lastSeenAt.delete(hostId);
    }
  }
  /** Test/diagnostic surface: how many pairing tokens are currently held. */
  get pairingCount(): number { return this.pairings.size; }
}

/**
 * Keeps the first `MAX_ALLOWED_DEVICES` entries of a set a host announced.
 * A host is authenticated but not trusted with the relay's memory: nothing
 * stops one from announcing a million device ids.
 */
export function capSet(ids: Set<string>): Set<string> {
  if (ids.size <= MAX_ALLOWED_DEVICES) return ids;
  return new Set([...ids].slice(0, MAX_ALLOWED_DEVICES));
}
