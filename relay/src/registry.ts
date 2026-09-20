export interface PeerSocket { send(data: string): void; close(code?: number, reason?: string): void }
export interface HostEntry { socket: PeerSocket; allowed: Set<string>; publicKey: string }
export interface ClientEntry { socket: PeerSocket }

export class Registry {
  private hosts = new Map<string, HostEntry>();
  private clients = new Map<string, ClientEntry>();
  private pairings = new Map<string, { hostId: string; expiresAt: number }>();
  private lastSeenAt = new Map<string, number>();
  // Devices that have ever paired with a host, for presence (online/offline) fan-out.
  // Deliberately separate from HostEntry.allowed: revocation removes forwarding
  // rights immediately but a revoked device should still learn the host went offline.
  private watchers = new Map<string, Set<string>>();
  registerHost(hostId: string, socket: PeerSocket, allowed: Set<string>, publicKey = "") {
    this.hosts.set(hostId, { socket, allowed, publicKey });
    const watching = this.watchers.get(hostId) ?? new Set<string>();
    for (const deviceId of allowed) watching.add(deviceId);
    this.watchers.set(hostId, watching);
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
    this.watchers.set(hostId, watching);
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
  createPairing(hostId: string, token: string, ttlMs: number, now: number) { this.pairings.set(token, { hostId, expiresAt: now + ttlMs }); }
  consumePairing(token: string, now: number) {
    const p = this.pairings.get(token); if (!p) return undefined;
    this.pairings.delete(token);
    return now <= p.expiresAt ? { hostId: p.hostId } : undefined;
  }
}
