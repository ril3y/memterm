export interface PeerSocket { send(data: string): void; close(code?: number, reason?: string): void }
export interface HostEntry { socket: PeerSocket; allowed: Set<string> }
export interface ClientEntry { socket: PeerSocket }

export class Registry {
  private hosts = new Map<string, HostEntry>();
  private clients = new Map<string, ClientEntry>();
  private pairings = new Map<string, { hostId: string; expiresAt: number }>();
  registerHost(hostId: string, socket: PeerSocket, allowed: Set<string>) { this.hosts.set(hostId, { socket, allowed }); }
  unregisterHost(hostId: string) { this.hosts.delete(hostId); }
  host(hostId: string) { return this.hosts.get(hostId); }
  registerClient(deviceId: string, socket: PeerSocket) { this.clients.set(deviceId, { socket }); }
  unregisterClient(deviceId: string) { this.clients.delete(deviceId); }
  client(deviceId: string) { return this.clients.get(deviceId); }
  createPairing(hostId: string, token: string, ttlMs: number, now: number) { this.pairings.set(token, { hostId, expiresAt: now + ttlMs }); }
  consumePairing(token: string, now: number) {
    const p = this.pairings.get(token); if (!p) return undefined;
    this.pairings.delete(token);
    return now <= p.expiresAt ? { hostId: p.hostId } : undefined;
  }
}
