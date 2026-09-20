import AppKit
import CryptoKit
import Foundation
import MemtermCore

// Remote attach (decision doc 2026-09-19): the host that lives inside the
// running app. It keeps ONE outbound WebSocket to the relay, pairs devices,
// runs an end-to-end-encrypted session per paired device, and hands the
// decrypted messages to the dispatcher (RemoteHost+Dispatch.swift), which
// drives real panes.
//
// Why outbound-only: the mini never opens a port, so remote attach works from
// behind NAT with nothing configured. The relay is blind — it routes
// envelopes by `to`/`from` and never holds a key — so "no cloud that can read
// your terminal" survives the feature.
//
// THREADING: every relay message is handled on the MAIN thread. The socket's
// completion handlers land on URLSession's delegate queue and immediately hop
// (`onMain`), because dispatch touches panes and AppKit, and SwiftTerm asserts
// the main thread. Sends are safe from anywhere (URLSessionWebSocketTask and
// RemoteSessionKeys are both thread-safe), but they are made from main too so
// the counters advance in the order the messages were produced.

/// What a device needs to reach this host, encoded into the pairing QR.
/// The field names are a cross-language contract: the TypeScript web client
/// parses this exact JSON out of the URL fragment.
struct PairingPayload: Codable, Equatable {
    /// The relay's `wss://…` base URL (no path).
    var relay: String
    var hostId: String
    /// DER SubjectPublicKeyInfo, base64 — what the device pins as "the host".
    var hostPublicKey: String
    /// 32 random bytes, base64url. Single-use, and the relay forgets it after
    /// 120 seconds.
    var token: String
    /// Epoch MILLISECONDS, so the browser can compare it to `Date.now()`
    /// without a format negotiation.
    var expiresAt: Int
}

final class RemoteHost {

    /// Settings ▸ Remote's status line, and the probe's connection assertion.
    /// `off` means disabled or suppressed in an automated run — nothing is
    /// dialing. `offline` means enabled but not currently connected (the
    /// relay is down, or the Mac has no network); a retry is scheduled.
    private(set) var probeState = "off"
    /// The last thing that went wrong, for the status line and the probe.
    /// Cleared on a successful auth.
    private(set) var probeLastError: String?
    var probeSessionCount: Int { sessions.count }

    /// Settings shows "Allow ‹name›?" and calls back with the answer. The
    /// SPKI is passed through so the UI never has to trust a name or an id —
    /// the key is the identity, everything else is a label.
    var onPairRequest: ((_ name: String, _ deviceId: String, _ publicKeySPKI: Data,
                         _ accept: @escaping (Bool) -> Void) -> Void)?
    /// Fired after the device list or the connection state changes, so an
    /// open Settings window can refresh itself.
    var onStateChange: (() -> Void)?

    unowned let app: MemtermAppDelegate
    let store: RemoteDeviceStore

    // MARK: - Session state

    /// One live, key-agreed conversation with one device. A class so dispatch
    /// can mutate `attachedPaneId` in place.
    final class Session {
        let deviceId: String
        let keys: RemoteSessionKeys
        var attachedPaneId: String?

        init(deviceId: String, keys: RemoteSessionKeys) {
            self.deviceId = deviceId
            self.keys = keys
        }
    }

    /// deviceId → session. One session per device: a fresh Hello from a
    /// device REPLACES its old session (a phone that dropped and came back
    /// must not be locked out by the corpse of its previous connection).
    private(set) var sessions: [String: Session] = [:]
    /// paneId → the fan-out stream, shared by every device watching that
    /// pane. Dropped when its last viewer leaves, which removes the pane tap.
    var streams: [String: RemotePaneStream] = [:]
    /// Unlock attempts are throttled per device so a stolen phone cannot
    /// brute-force a workspace passphrase (no workspace is lockable yet).
    var unlockLimiter = UnlockRateLimiter()

    // MARK: - Connection state

    private var identityCache: RemoteIdentity?
    private var task: URLSessionWebSocketTask?
    private var enabled = false
    private var relayBase: URL?
    private var reconnectDelay: TimeInterval = 1
    private var reconnectWork: DispatchWorkItem?
    private var pingWork: DispatchWorkItem?
    /// A token minted by `startPairing()` while the socket was down, or
    /// before the relay had authed us; sent as soon as we are authed.
    private var pendingPairToken: String?
    /// Generation counter: every connect attempt bumps it, and a callback
    /// from an older socket is ignored. Without it, a slow failure from a
    /// socket we already replaced would schedule a second reconnect loop.
    private var generation = 0

    init(app: MemtermAppDelegate, store: RemoteDeviceStore = RemoteDeviceStore()) {
        self.app = app
        self.store = store
    }

    /// The long-lived signing key, resolved once per launch. Deliberately not
    /// touched in `init`: creating the host must not reach into the Keychain,
    /// so an install with remote off never prompts and never stores a key.
    var identity: RemoteIdentity {
        if let identityCache { return identityCache }
        let fresh = store.loadOrCreateIdentity()
        identityCache = fresh
        return fresh
    }

    var hostId: String { identity.id }

    // MARK: - Config

    /// Connect or disconnect to match Settings ▸ Remote.
    ///
    /// Automated runs (UI probe, smoke) never dial a real relay: a probe that
    /// opened a socket to the founder's Fly app would make the test suite
    /// depend on the internet and announce the machine to a public service.
    /// The exception is a loopback relay, which is exactly what Task 12's
    /// end-to-end leg starts on 127.0.0.1 — so the probe drives the real
    /// code path without leaving the machine.
    func applyConfig(_ config: Config) {
        let url = URL(string: config.remoteRelayURL)
        let relayHost = url?.host ?? ""
        let loopback = relayHost == "127.0.0.1" || relayHost == "localhost"
        let automated = ProbeSupport.isUIProbe || ProbeSupport.isSmoke
        guard config.remoteEnabled, !automated || loopback else {
            disconnect(state: "off")
            return
        }
        guard let url, !relayHost.isEmpty else {
            // The switch is on but the address is not usable. Say so, rather
            // than showing a silent "Off" that looks like the switch failed.
            disconnect(state: "off")
            setState("off", error: "relay URL is not usable")
            return
        }
        if enabled, relayBase == url, task != nil { return }  // nothing changed
        disconnect(state: "off")
        enabled = true
        relayBase = url
        connect()
    }

    // MARK: - Pairing

    /// Mints a single-use pairing token and registers it with the relay.
    /// The caller turns the returned payload into the QR code; the relay
    /// forgets the token after 120 seconds or one use, whichever comes first.
    @discardableResult
    func startPairing(now: Date = Date()) -> PairingPayload {
        // A pairing token is the only thing standing between a stranger and a
        // pair REQUEST reaching the user, so it comes from the system CSPRNG
        // rather than a UUID.
        var bytes = Data(count: 32)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        let token = Self.base64url(bytes)
        pendingPairToken = token
        sendPairTokenIfPossible()
        let expiry = now.addingTimeInterval(120)
        return PairingPayload(
            relay: relayBase?.absoluteString ?? app.config.remoteRelayURL,
            hostId: hostId,
            hostPublicKey: identity.publicKeySPKI.base64EncodedString(),
            token: token,
            expiresAt: Int(expiry.timeIntervalSince1970 * 1000))
    }

    /// The URL the QR encodes: the relay's own web client, with the payload
    /// in the FRAGMENT so it is never sent to the relay's HTTP server — the
    /// browser keeps it client-side, which is the point of a blind relay.
    static func pairingURL(for payload: PairingPayload) -> URL? {
        guard let relay = URL(string: payload.relay),
              var parts = URLComponents(url: relay, resolvingAgainstBaseURL: false),
              let json = try? JSONEncoder().encode(payload)
        else { return nil }
        parts.scheme = relay.scheme == "ws" ? "http" : "https"
        parts.path = "/"
        parts.fragment = "pair=" + base64url(json)
        return parts.url
    }

    /// Drops a device: it leaves the store, the relay's allow-list is
    /// replaced (so its very next envelope is refused), and any live session
    /// and pane viewers it owns are torn down immediately.
    func revoke(deviceId: String) {
        store.remove(id: deviceId)
        endSession(deviceId: deviceId)
        sendAllowed()
        onStateChange?()
    }

    // MARK: - Connection

    private func connect() {
        guard enabled, let base = relayBase else { return }
        generation += 1
        let gen = generation
        // The relay's two endpoints differ only by path; `/host` is the one
        // that may announce an allow-list.
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/host"
        guard let url = parts?.url else {
            setState("off", error: "relay URL is not usable")
            return
        }
        setState("connecting", error: probeLastError)
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receive(on: socket, generation: gen)
        schedulePing(generation: gen)
    }

    private func receive(on socket: URLSessionWebSocketTask, generation gen: Int) {
        socket.receive { [weak self] result in
            Self.onMain {
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.handleSocketFailure(error)
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleRelay(Data(text.utf8))
                    case .data(let data):
                        self.handleRelay(data)
                    @unknown default:
                        break
                    }
                    self.receive(on: socket, generation: gen)
                }
            }
        }
    }

    private func handleSocketFailure(_ error: Error) {
        // Every session's keys are bound to this connection's handshake, so a
        // dropped socket ends them all; the device re-Hellos on reconnect.
        tearDownAllSessions()
        task = nil
        pingWork?.cancel()
        guard enabled else { return }
        setState("offline", error: error.localizedDescription)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: work)
        // 1 s → 30 s: fast enough that a relay restart is invisible, slow
        // enough that a relay that is down for a day is not hammered.
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    /// Fly (and most proxies) cut an idle WebSocket. A ping every 30 s keeps
    /// an attached-but-quiet session alive instead of making it reconnect and
    /// re-handshake every few minutes.
    private func schedulePing(generation gen: Int) {
        pingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, let task = self.task else { return }
            task.sendPing { _ in }
            self.schedulePing(generation: gen)
        }
        pingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private func disconnect(state: String) {
        enabled = false
        generation += 1
        reconnectWork?.cancel()
        pingWork?.cancel()
        reconnectDelay = 1
        tearDownAllSessions()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        relayBase = nil
        setState(state, error: nil)
    }

    private func setState(_ state: String, error: String?) {
        probeState = state
        probeLastError = error
        onStateChange?()
    }

    // MARK: - Relay protocol

    /// The relay's own control messages (everything that is not an envelope).
    /// All of it is untrusted input: a field that is missing or the wrong
    /// type just ends the handler, never a force-unwrap.
    private func handleRelay(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        switch type {
        case "challenge":
            guard let nonceB64 = object["nonce"] as? String,
                  let nonce = Data(base64Encoded: nonceB64)
            else { return }
            sendAuth(nonce: nonce)
        case "authed":
            reconnectDelay = 1
            setState("connected", error: nil)
            sendAllowed()
            sendPairTokenIfPossible()
        case "pair-request":
            handlePairRequest(object)
        case "refused":
            // `not-allowed` after a revoke is the expected outcome, not a
            // failure worth alarming the user about; surface it as the last
            // error and let the status line stay "connected".
            probeLastError = "relay refused: \((object["reason"] as? String) ?? "unknown")"
            onStateChange?()
        case "env":
            guard let envelope = RemoteEnvelope.decode(data) else { return }
            handleEnvelope(envelope)
        default:
            break
        }
    }

    private func sendAuth(nonce: Data) {
        // The relay verifies this signature over the RAW nonce bytes. Hello
        // signatures carry a domain label precisely so that a signature
        // gathered here can never be replayed as one.
        let payload: [String: Any] = [
            "type": "auth",
            "publicKey": identity.publicKeySPKI.base64EncodedString(),
            "signature": identity.sign(nonce).base64EncodedString(),
            "allowed": store.allowedIds,
        ]
        sendJSON(payload)
    }

    /// Replaces the relay's allow-list with the store's. The host's device
    /// list is the truth; the relay only caches it for the current
    /// connection, which is why this is re-sent on every auth and after every
    /// pair or revoke.
    private func sendAllowed() {
        sendJSON(["type": "allowed", "devices": store.allowedIds])
    }

    private func sendPairTokenIfPossible() {
        guard probeState == "connected", let token = pendingPairToken else { return }
        sendJSON(["type": "pair-token", "token": token])
        // Single use at the relay; a second QR mints a second token.
        pendingPairToken = nil
    }

    private func handlePairRequest(_ object: [String: Any]) {
        guard let publicKeyB64 = object["publicKey"] as? String,
              let spki = Data(base64Encoded: publicKeyB64),
              RemoteDeviceStore.isValidSPKI(spki)
        else { return }
        // The relay tells us a deviceId, but we never store it: the id is
        // whatever the KEY hashes to. If those disagree, the relay is lying
        // or broken, and trusting its id would pin the wrong identity.
        let deviceId = RemoteIdentity.peerId(forSPKI: spki)
        let name = (object["name"] as? String) ?? "Device"
        let safeName = String(name.prefix(64))

        let accept: (Bool) -> Void = { [weak self] allowed in
            Self.onMain {
                guard let self else { return }
                if allowed {
                    self.store.add(PairedDevice(id: deviceId, name: safeName,
                                                publicKeySPKI: spki, pairedAt: Date(),
                                                lastSeen: nil))
                    self.sendAllowed()
                    self.onStateChange?()
                }
                self.sendJSON(["type": "pair-answer", "deviceId": deviceId, "accept": allowed])
            }
        }
        guard let onPairRequest else {
            // Nobody is watching (Settings is closed): deny rather than let a
            // pairing complete without the user ever seeing the prompt.
            accept(false)
            return
        }
        onPairRequest(safeName, deviceId, spki, accept)
    }

    // MARK: - Envelopes

    private func handleEnvelope(_ envelope: RemoteEnvelope) {
        // `from` is relay-attested (the relay closes any socket whose `from`
        // is not its authenticated id) and is used ONLY as a lookup key. The
        // identity we bind the session to is always re-derived from the SPKI
        // we stored at pairing time — see `startSession`.
        guard let device = store.device(id: envelope.from) else { return }
        store.touch(id: device.id)

        if let hello = HelloWire.decode(envelope.payload) {
            startSession(with: device, hello: hello)
            return
        }
        guard let session = sessions[device.id] else { return }
        do {
            let plaintext = try session.keys.open(envelope.payload)
            guard let message = RemoteMessage.decode(plaintext) else {
                throw RemoteCryptoError.malformed
            }
            dispatch(message, session: session)
        } catch {
            // A record that will not open is a replay, a forgery, or a
            // desynced counter. None of them are recoverable and none of them
            // may be acted on: the session dies and the device re-handshakes.
            log("session with \(device.id) torn down: \(error)")
            endSession(deviceId: device.id)
        }
    }

    /// The client speaks first. Its Hello rides in the clear inside the
    /// envelope (there is no key yet), authenticated by a signature over a
    /// domain-separated payload that we check against the SPKI stored when
    /// the user accepted this device.
    private func startSession(with device: PairedDevice, hello: RemoteHandshake.Hello) {
        guard RemoteHandshake.verifyHello(hello, peerSPKI: device.publicKeySPKI) else {
            log("rejected Hello from \(device.id): bad signature")
            return
        }
        // Replace any previous session for this device before deriving new
        // keys, so its pane viewers do not leak.
        endSession(deviceId: device.id)

        let (mine, ephemeral) = RemoteHandshake.makeHello(identity: identity)
        // Both ids come from verified keys, never from a wire field: that
        // binding is what stops an unknown-key-share attack.
        let deviceId = RemoteIdentity.peerId(forSPKI: device.publicKeySPKI)
        guard let keys = try? RemoteHandshake.deriveKeys(
            myEphemeral: ephemeral,
            peerEphemeralRaw: hello.ephemeralRaw,
            hostId: identity.id,
            deviceId: deviceId,
            iAmHost: true)
        else {
            log("rejected Hello from \(deviceId): unusable ephemeral key")
            return
        }
        sendEnvelope(to: deviceId, payload: HelloWire.encode(mine))
        sessions[deviceId] = Session(deviceId: deviceId, keys: keys)
        onStateChange?()
    }

    /// Ends one device's session: its pane viewers go first, so a torn-down
    /// session never leaves a tap fanning bytes at a dead socket.
    func endSession(deviceId: String) {
        guard let session = sessions.removeValue(forKey: deviceId) else { return }
        if let paneId = session.attachedPaneId { removeViewer(deviceId, from: paneId) }
        onStateChange?()
    }

    private func tearDownAllSessions() {
        // Snapshot the ids: endSession mutates `sessions`.
        for deviceId in Array(sessions.keys) { endSession(deviceId: deviceId) }
    }

    // MARK: - Sending

    /// One sealed inner message to one device. Sealing bumps that direction's
    /// counter, so this is the only path host→device messages take.
    func send(_ message: RemoteMessage, to deviceId: String) {
        guard let session = sessions[deviceId],
              let record = try? session.keys.seal(message.encode())
        else { return }
        sendEnvelope(to: deviceId, payload: record)
    }

    /// Pushes `tree-changed` to every attached device. Called from
    /// `refreshWorkspaceChips()`, which already runs on every topology change
    /// the UI cares about — so a phone's tree follows the Mac's for free.
    func broadcastTreeChanged() {
        guard !sessions.isEmpty else { return }
        pruneClosedPanes()
        for deviceId in Array(sessions.keys) { send(.treeChanged, to: deviceId) }
    }

    private func sendEnvelope(to deviceId: String, payload: Data) {
        let envelope = RemoteEnvelope(to: deviceId, from: identity.id, payload: payload)
        guard let text = String(data: envelope.encode(), encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }

    // MARK: - Helpers

    /// The handshake's clear-text wire form. Separate from `RemoteMessage`
    /// because it is the one payload that is NOT sealed — keeping it a
    /// distinct shape means a Hello can never be confused for an inner
    /// message, in either direction.
    enum HelloWire {
        private struct Wire: Codable {
            var hs: String
            var eph: Data
            var sig: Data
        }

        static func encode(_ hello: RemoteHandshake.Hello) -> Data {
            let wire = Wire(hs: "hello", eph: hello.ephemeralRaw, sig: hello.signature)
            return (try? JSONEncoder().encode(wire)) ?? Data()
        }

        static func decode(_ data: Data) -> RemoteHandshake.Hello? {
            guard let wire = try? JSONDecoder().decode(Wire.self, from: data),
                  wire.hs == "hello"
            else { return nil }
            return RemoteHandshake.Hello(ephemeralRaw: wire.eph, signature: wire.sig)
        }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Hops to main unless already there. Re-entering `DispatchQueue.main.async`
    /// from the main thread would defer dispatch by a turn, which would let a
    /// later message overtake an earlier one.
    static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    func log(_ message: String) {
        // Automated runs assert on exact probe output; remote chatter would
        // be noise there.
        guard !ProbeSupport.quiet else { return }
        print("memterm remote: \(message)")
    }
}
