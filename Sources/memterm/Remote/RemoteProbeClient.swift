import CryptoKit
import Foundation
import MemtermCore

// Task 12's headless DEVICE-side client: the relay/handshake/RemoteMessage
// protocol driven from a plain Swift object instead of a browser, so the
// remote-end-to-end probe leg exercises the REAL relay and the REAL
// RemoteHost — nothing here is mocked. This is the Swift twin of
// relay/web/src/relay.ts + app.ts (the reference device implementation);
// keep the two in lockstep if the wire protocol ever changes.
//
// THREADING: every inbound relay message is handled on the MAIN thread (the
// same rule RemoteHost.swift documents), because the probe's ProbeStep
// conditions poll this object's properties from main — without the hop,
// URLSession's delegate-queue callback and the poll would race on plain
// Swift vars.
final class RemoteProbeClient {
    let identity = RemoteIdentity.generate()
    var deviceId: String { identity.id }

    private var task: URLSessionWebSocketTask?
    private var sessionKeys: RemoteSessionKeys?
    private var myEphemeral: P256.KeyAgreement.PrivateKey?
    private var hostId = ""
    private var hostPublicKeySPKI = Data()
    private var pendingPairToken: String?
    private var pendingPairName = "probe-client"

    // Polled by the leg's ProbeStep conditions; written only on main.
    private(set) var authed = false
    /// `nil` while the pairing answer is still in flight, `false` on
    /// `pair-denied` — checked by the probe leg for a clear failure message
    /// instead of a generic handshake timeout.
    private(set) var paired: Bool?
    private(set) var handshakeComplete = false
    private(set) var lastTree: RemoteTree?
    private(set) var lastScreen: (cols: Int, rows: Int, bytes: Data)?
    private(set) var receivedOutput = Data()
    private(set) var lastResized: (cols: Int, rows: Int)?
    private(set) var lastRefusedReason: String?
    /// Bumped on every `treeChanged` envelope; the remote-close-prunes probe
    /// step snapshots this before closing a pane and polls for it to move.
    private(set) var treeChangedCount = 0
    /// Bumped on every `screen` envelope (a fresh attach's initial frame) —
    /// a monotonic signal the remote-close-prunes leg can wait on instead of
    /// comparing screen dimensions, which a second pane could coincidentally
    /// share with the first.
    private(set) var screenCount = 0

    // MARK: - Connection

    /// Opens (or re-opens, after a relay restart) the `/client` socket and
    /// runs the challenge/auth handshake. Pairing is NOT re-sent here: a
    /// reconnect only needs a fresh auth, since the host's own device store
    /// — not the relay's in-memory registry — is what remembers pairing.
    func connect(relay: URL) {
        authed = false
        var parts = URLComponents(url: relay, resolvingAgainstBaseURL: false)
        parts?.path = "/client"
        guard let url = parts?.url else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        task = socket
        socket.resume()
        receive(on: socket)
    }

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                DispatchQueue.main.async { self.authed = false }
            case .success(let message):
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let raw): data = raw
                @unknown default: return self.receive(on: socket)
                }
                DispatchQueue.main.async { self.handle(data) }
                self.receive(on: socket)
            }
        }
    }

    private func handle(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        switch type {
        case "challenge":
            guard let nonceB64 = object["nonce"] as? String, let nonce = Data(base64Encoded: nonceB64)
            else { return }
            sendJSON(["type": "auth",
                      "publicKey": identity.publicKeySPKI.base64EncodedString(),
                      "signature": identity.sign(nonce).base64EncodedString()])
        case "authed":
            authed = true
            sendPairIfPending()
        case "paired":
            guard let hostIdValue = object["hostId"] as? String,
                  let hostKeyB64 = object["hostPublicKey"] as? String,
                  let spki = Data(base64Encoded: hostKeyB64)
            else { return }
            hostId = hostIdValue
            hostPublicKeySPKI = spki
            paired = true
            sendHello()
        case "pair-denied":
            paired = false
        case "refused":
            lastRefusedReason = (object["reason"] as? String) ?? "unknown"
        case "env":
            guard let envelope = RemoteEnvelope.decode(data) else { return }
            handleEnvelope(envelope)
        default:
            break
        }
    }

    // MARK: - Pairing + handshake

    /// Queues a pairing request; sent immediately if already authed, or on
    /// the next "authed" otherwise — the relay only accepts a peer's first
    /// message as its auth reply, so "pair" can never be sent ahead of it.
    func pair(_ payload: PairingPayload, name: String = "probe-client") {
        pendingPairToken = payload.token
        pendingPairName = name
        sendPairIfPending()
    }

    private func sendPairIfPending() {
        guard authed, let token = pendingPairToken else { return }
        sendJSON(["type": "pair", "token": token,
                  "publicKey": identity.publicKeySPKI.base64EncodedString(),
                  "name": pendingPairName])
        pendingPairToken = nil
    }

    /// The client speaks first (mirrors RemoteHost.startSession): a fresh
    /// ephemeral, signed and sent in the clear inside an envelope, kept
    /// around until the host's own Hello comes back.
    private func sendHello() {
        let (hello, ephemeral) = RemoteHandshake.makeHello(identity: identity)
        myEphemeral = ephemeral
        sendEnvelope(to: hostId, payload: helloWireEncode(hello))
    }

    private func handleEnvelope(_ envelope: RemoteEnvelope) {
        guard envelope.to == deviceId else { return }
        if let hello = helloWireDecode(envelope.payload) {
            guard RemoteHandshake.verifyHello(hello, peerSPKI: hostPublicKeySPKI),
                  let ephemeral = myEphemeral,
                  let keys = try? RemoteHandshake.deriveKeys(
                      myEphemeral: ephemeral, peerEphemeralRaw: hello.ephemeralRaw,
                      hostId: hostId, deviceId: deviceId, iAmHost: false)
            else { return }
            sessionKeys = keys
            handshakeComplete = true
            return
        }
        guard let keys = sessionKeys,
              let plaintext = try? keys.open(envelope.payload),
              let message = RemoteMessage.decode(plaintext)
        else { return }
        switch message {
        case .tree(let tree): lastTree = tree
        case .screen(let cols, let rows, let bytes):
            lastScreen = (cols, rows, bytes)
            screenCount += 1
        case .output(let bytes): receivedOutput.append(bytes)
        case .resized(let cols, let rows): lastResized = (cols, rows)
        case .refused(let reason): lastRefusedReason = reason
        case .treeChanged: treeChangedCount += 1
        default: break
        }
    }

    // MARK: - Outbound RemoteMessages

    /// Sealed with whatever session key this client currently holds. Safe to
    /// call even with a stale key (e.g. right after a revoke, before any
    /// fresh handshake): the relay's allow-list check runs before the
    /// envelope is ever handed to the host, so a rejected send never needs a
    /// valid seal to prove the point.
    func send(_ message: RemoteMessage) {
        guard let keys = sessionKeys, let record = try? keys.seal(message.encode()) else { return }
        sendEnvelope(to: hostId, payload: record)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    // MARK: - Wire helpers (mirrors RemoteHost.HelloWire, which is private there)

    private struct HelloWireData: Codable { var hs: String; var eph: Data; var sig: Data }

    private func helloWireEncode(_ hello: RemoteHandshake.Hello) -> Data {
        let wire = HelloWireData(hs: "hello", eph: hello.ephemeralRaw, sig: hello.signature)
        return (try? JSONEncoder().encode(wire)) ?? Data()
    }

    private func helloWireDecode(_ data: Data) -> RemoteHandshake.Hello? {
        guard let wire = try? JSONDecoder().decode(HelloWireData.self, from: data), wire.hs == "hello"
        else { return nil }
        return RemoteHandshake.Hello(ephemeralRaw: wire.eph, signature: wire.sig)
    }

    private func sendEnvelope(to: String, payload: Data) {
        let envelope = RemoteEnvelope(to: to, from: deviceId, payload: payload)
        guard let text = String(data: envelope.encode(), encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8)
        else { return }
        task?.send(.string(text)) { _ in }
    }
}
