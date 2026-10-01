import CryptoKit
import Foundation
import MemtermRemoteKit

/// One paired Mac, while the app is in the foreground and that Mac is on
/// screen. Owns the relay connection, the handshake, the session keys and
/// the attached pane.
///
/// Main-actor throughout: `RelayConnection` requires main-queue calls, and
/// `RemoteSessionKeys`' counters must be consumed in order — doing both on
/// one actor is what makes "records go out in the order they were sealed"
/// true by construction rather than by care.
///
/// `CryptoKit` import note: `signer` is a `RemoteSigner`, not a concrete
/// `RemoteIdentity` (that is the whole point — a phone's signer is a Secure
/// Enclave key, which has no `RemoteIdentity` representation). The kit's
/// `RemoteHandshake.makeHello(signer:)` takes a `RemoteSigner` for exactly
/// this reason, so this type does not build its own Hello — but
/// `RemoteHandshake.deriveKeys(myEphemeral:…)`'s first parameter is a raw
/// CryptoKit key type, so holding the ephemeral between sending our Hello
/// and the Mac's reply still requires this import. See
/// `scripts/check-extension-firewall.sh`'s `remote-app` line.
@MainActor
public final class HostSession: ObservableObject {
    public enum Phase: Equatable {
        case idle, connecting, handshaking, ready
        case attached(paneId: String)
        case offline(since: Date?)
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var tree: RemoteTree?
    /// Screen bytes then output chunks for the attached pane, newest last.
    public var onOutput: ((Data) -> Void)?

    private let host: PairedHost
    private let signer: RemoteSigner
    private let makeConnection: (URL, RelayConnection.Events) -> RelayConnection
    private var connection: RelayConnection?
    private var keys: RemoteSessionKeys?

    /// The handshake in flight, and the generation that identifies it. A
    /// second `start()` (or a fresh "authed") bumps the generation, so a
    /// Hello reply that belongs to a superseded attempt is dropped rather
    /// than racing the live one into `keys`.
    private var pendingEphemeral: P256.KeyAgreement.PrivateKey?
    private var pendingGeneration: Int?
    private var handshakeGeneration = 0

    private var attachedPaneId: String?
    /// Survives a background/foreground cycle so the viewer comes back to
    /// the pane it was on, when that pane still exists.
    private var lastAttachedPaneId: String?

    /// The Mac's peer id, derived fresh from the pinned SPKI every time —
    /// never taken from `host.id` as a shortcut, so there is exactly one
    /// place this binding can go wrong, and it is this one.
    private var hostId: String { RemoteIdentity.peerId(forSPKI: host.publicKeySPKI) }

    public init(host: PairedHost, signer: RemoteSigner,
                makeConnection: @escaping (URL, RelayConnection.Events) -> RelayConnection) {
        self.host = host; self.signer = signer; self.makeConnection = makeConnection
    }

    // MARK: - Lifecycle

    public func start() {
        handshakeGeneration += 1
        connection?.stop()
        keys = nil
        pendingEphemeral = nil
        pendingGeneration = nil
        attachedPaneId = nil
        phase = .connecting

        var events = RelayConnection.Events()
        events.onControl = { [weak self] object in self?.handleControl(object) }
        events.onEnvelope = { [weak self] envelope in self?.handleEnvelope(envelope) }
        let conn = makeConnection(host.relay, events)
        connection = conn
        conn.start()
    }

    public func stop() {
        connection?.stop()
        connection = nil
        keys = nil
        pendingEphemeral = nil
        pendingGeneration = nil
        attachedPaneId = nil
        phase = .idle
    }

    public func sceneBecameActive() { start() }
    public func sceneWentToBackground() { stop() }

    // MARK: - Viewer actions

    public func attach(paneId: String) {
        attachedPaneId = paneId
        lastAttachedPaneId = paneId
        phase = .attached(paneId: paneId)
        send(.attach(paneId: paneId))
    }

    public func detach() {
        attachedPaneId = nil
        lastAttachedPaneId = nil
        phase = .ready
        send(.detach)
    }

    public func input(_ bytes: Data) {
        send(.input(bytes))
    }

    public func resize(cols: Int, rows: Int) {
        send(.resize(cols: cols, rows: rows))
    }

    // MARK: - Relay control frames

    private func handleControl(_ object: [String: Any]) {
        guard let type = object["type"] as? String else { return }
        switch type {
        case "authed":
            beginHandshake()
        case "offline":
            let since = (object["lastSeen"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            phase = .offline(since: since)
        case "online":
            start()
        case "refused":
            let reason = object["reason"] as? String ?? "refused"
            if reason == "not-allowed" {
                phase = .failed("This Mac no longer allows this device.")
            } else {
                phase = .failed(reason)
            }
        default:
            break
        }
    }

    /// The phone speaks first: a fresh ephemeral, signed by whatever signer
    /// we were given, sent in the clear (there is no key yet) inside an
    /// envelope. `RemoteHandshake.makeHello(signer:)` and `HelloWire` are the
    /// kit's shared implementations — the same ones the Mac host and the
    /// headless probe client use — so there is exactly one wire format.
    private func beginHandshake() {
        handshakeGeneration += 1
        let generation = handshakeGeneration
        guard let (hello, ephemeral) = try? RemoteHandshake.makeHello(signer: signer) else {
            phase = .failed("Could not sign the handshake.")
            return
        }
        pendingEphemeral = ephemeral
        pendingGeneration = generation
        phase = .handshaking

        let envelope = RemoteEnvelope(to: hostId, from: signer.id, payload: HelloWire.encode(hello))
        connection?.send(envelope: envelope, completion: nil)
    }

    // MARK: - Envelopes

    private func handleEnvelope(_ envelope: RemoteEnvelope) {
        guard envelope.from == hostId else { return }

        if let hello = HelloWire.decode(envelope.payload) {
            // The Mac's half of the handshake, in the clear. A Hello that
            // does not match the handshake we are currently waiting on
            // (none pending, or a superseded one) is dropped silently: it
            // is either a duplicate or a stray reply to an attempt we have
            // already moved past, and must never be let into `keys`.
            guard let ephemeral = pendingEphemeral, let generation = pendingGeneration,
                  generation == handshakeGeneration
            else { return }
            guard RemoteHandshake.verifyHello(hello, peerSPKI: host.publicKeySPKI) else {
                phase = .failed("Could not verify this Mac's identity.")
                return
            }
            guard let derived = try? RemoteHandshake.deriveKeys(
                myEphemeral: ephemeral,
                peerEphemeralRaw: hello.ephemeralRaw,
                hostId: hostId,
                deviceId: signer.id,
                iAmHost: false)
            else {
                phase = .failed("Could not complete the handshake.")
                return
            }
            // Re-checked after deriving: a synchronous path today, but the
            // generation guard is what keeps this correct if signing or
            // derivation ever gains a genuine async step.
            guard generation == handshakeGeneration else { return }
            keys = derived
            pendingEphemeral = nil
            pendingGeneration = nil
            send(.list)
            return
        }

        guard let keys else { return }
        let plaintext: Data
        do {
            plaintext = try keys.open(envelope.payload)
        } catch {
            // A record that will not open is a replay, a forgery, or a
            // desynced counter — none of them recoverable. The session ends
            // rather than stalling on a connection it can no longer trust.
            phase = .failed("Lost sync with this Mac.")
            return
        }
        guard let message = RemoteMessage.decode(plaintext) else {
            phase = .failed("Received something this app could not understand.")
            return
        }
        handle(message)
    }

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .tree(let newTree):
            tree = newTree
            if let current = attachedPaneId {
                if !ViewerTree.contains(paneId: current, in: newTree) {
                    attachedPaneId = nil
                    phase = .ready
                }
            } else if let last = lastAttachedPaneId, ViewerTree.contains(paneId: last, in: newTree) {
                attach(paneId: last)
            } else {
                phase = .ready
            }
        case .screen(_, _, let bytes):
            if let paneId = attachedPaneId { phase = .attached(paneId: paneId) }
            onOutput?(bytes)
        case .output(let bytes):
            onOutput?(bytes)
        case .treeChanged:
            send(.list)
        case .refused(let reason):
            phase = .failed(reason)
        case .resized:
            break // the view asked for it; nothing to surface
        case .list, .attach, .detach, .input, .resize, .newTab, .unlock:
            break // client-only: we send these, we never receive them
        }
    }

    // MARK: - Sending

    private func send(_ message: RemoteMessage) {
        guard let keys, let connection else { return }
        guard let sealed = try? keys.seal(message.encode()) else { return }
        let envelope = RemoteEnvelope(to: hostId, from: signer.id, payload: sealed)
        connection.send(envelope: envelope, completion: nil)
    }
}
