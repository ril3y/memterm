import Foundation
import MemtermRemoteKit

/// The pairing payload the Mac's QR fragment carries — `RemoteHost.swift`'s
/// own `PairingPayload` (not exported) mints the matching JSON, so every
/// field name, every encoding, and `expiresAt`'s epoch-millisecond unit here
/// must agree with it exactly, or no phone can ever pair. `hostPublicKey` is
/// standard base64 (the Mac encodes it with `Data.base64EncodedString()`,
/// not the base64url the token and secret use) — see `makePairingPayload`.
public struct PairingPayload: Codable, Equatable {
    public var relay: String
    public var hostId: String
    public var hostPublicKey: String
    public var token: String
    public var secret: String
    public var expiresAt: Int

    public init(relay: String, hostId: String, hostPublicKey: String,
                token: String, secret: String, expiresAt: Int) {
        self.relay = relay; self.hostId = hostId; self.hostPublicKey = hostPublicKey
        self.token = token; self.secret = secret; self.expiresAt = expiresAt
    }
}

/// Drives one scan-to-paired attempt. This is the security-critical half of
/// pairing (security review C2): the Mac already refuses to prompt unless
/// the device's `proof` matches the secret half of the code it is showing,
/// and this is the other side of that same check — it refuses to trust the
/// Mac's `paired` reply unless BOTH the host id and the host's public key
/// equal what the QR itself carried, and the key actually hashes to that id.
/// A relay that forwards a doctored `paired` frame — a different host, or
/// the right host but a substituted key — is caught here, before anything
/// is stored or the phone starts trusting that key for a live session.
///
/// One `PairingFlow` is good for one attempt: `scanned` after a `.paired` or
/// terminal `.refused` starts a fresh one (any previous connection is torn
/// down first).
@MainActor
public final class PairingFlow: ObservableObject {
    public enum Phase: Equatable {
        case idle, confirming(PairingPayload), waiting, paired(PairedHost), refused(String)
    }

    @Published public private(set) var phase: Phase = .idle

    private let signer: RemoteSigner
    private let store: PairedHostStoring
    private let makeConnection: (URL, RelayConnection.Events) -> RelayConnection
    private let now: () -> Date

    private var connection: RelayConnection?
    /// The payload the current attempt was scanned from — the single source
    /// of truth a `paired` reply is checked against. Never replaced by
    /// anything that arrives over the wire.
    private var scannedPayload: PairingPayload?
    /// The name the person gave this Mac on the confirm screen (Task 2
    /// review finding: the QR payload and the relay's `paired` reply carry
    /// no name at all, so the phone is the only place one can come from).
    /// Set by `confirm(name:)`, consumed by `handlePaired` — never anything
    /// read off the wire.
    private var confirmedName = "Mac"

    public init(signer: RemoteSigner, store: PairedHostStoring,
                makeConnection: @escaping (URL, RelayConnection.Events) -> RelayConnection,
                now: @escaping () -> Date = Date.init) {
        self.signer = signer
        self.store = store
        self.makeConnection = makeConnection
        self.now = now
    }

    /// Shown next to the Mac's "Allow ‹name›?" prompt so the person can
    /// confirm they are looking at the same device on both screens.
    public var deviceKeyId: String {
        RemoteIdentity.peerId(forSPKI: signer.publicKeySPKI)
    }

    // MARK: - Scanning

    /// Reads a scanned URL's `#pair=` fragment. Every failure here refuses
    /// WITHOUT opening a socket — there is nothing yet to dial, since the
    /// relay named inside an unreadable, expired, or insecure code is not
    /// trusted enough to even connect to.
    @discardableResult
    public func scanned(_ url: URL) -> Bool {
        teardownConnection()
        scannedPayload = nil

        guard let fragment = url.fragment, fragment.hasPrefix("pair=") else {
            phase = .refused("That is not a memterm pairing code.")
            return false
        }
        let encoded = String(fragment.dropFirst("pair=".count))
        guard
            let json = RemotePairing.data(fromBase64url: encoded),
            let payload = try? JSONDecoder().decode(PairingPayload.self, from: json)
        else {
            phase = .refused("That QR code could not be read.")
            return false
        }
        // Refuse a malformed host key here, at decode time, rather than
        // letting it fail later and confusingly during the handshake
        // (Task 2 review finding). `RemoteIdentity.x963(fromSPKI:)` is the
        // kit's own well-formedness check (length + DER header) — reused
        // rather than re-deriving those constants in this module.
        guard
            let hostKeySPKI = Data(base64Encoded: payload.hostPublicKey),
            RemoteIdentity.x963(fromSPKI: hostKeySPKI) != nil
        else {
            phase = .refused("That pairing code's Mac key is not something this app understands.")
            return false
        }
        guard payload.expiresAt > Int(now().timeIntervalSince1970 * 1000) else {
            phase = .refused("This pairing code has expired. Ask for a new one.")
            return false
        }
        // The routing token is always `RemotePairing.routingTokenLength`
        // base64url characters (16 bytes); the secret is the other 16-byte
        // half of the same 32-byte split (`RemotePairing.tokenBytes / 2` —
        // `split(_:)`'s halving is the public contract here, since the halt
        // itself is not exposed). Anything else is not a code this app
        // minted the matching proof scheme for.
        guard
            payload.token.count == RemotePairing.routingTokenLength,
            let secretData = RemotePairing.data(fromBase64url: payload.secret),
            secretData.count == RemotePairing.tokenBytes / 2
        else {
            phase = .refused("That pairing code is not in a format this app understands.")
            return false
        }
        guard let relayURL = URL(string: payload.relay), relayURL.scheme?.lowercased() == "wss" else {
            phase = .refused("This code names a relay this app will not connect to.")
            return false
        }

        scannedPayload = payload
        phase = .confirming(payload)
        return true
    }

    // MARK: - Confirm / cancel

    /// The person pressed Pair: open the relay connection the QR named (and
    /// ONLY that relay — never the scanned page's own origin) and let the
    /// challenge/auth handshake run. The actual `pair` request is sent once
    /// `authed` arrives — see `handleControl`.
    ///
    /// - Parameter name: What to call this Mac once paired, as typed on the
    ///   confirm screen (defaulting to "Mac" — the same placeholder a
    ///   freshly paired device showed before this parameter existed, so
    ///   existing callers and tests keep compiling). Blank or
    ///   whitespace-only input falls back to "Mac" too.
    public func confirm(name: String = "Mac") {
        guard case .confirming(let payload) = phase, let relayURL = URL(string: payload.relay) else { return }
        teardownConnection()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        confirmedName = trimmed.isEmpty ? "Mac" : trimmed

        var events = RelayConnection.Events()
        events.onControl = { [weak self] object in self?.handleControl(object) }
        let conn = makeConnection(relayURL, events)
        connection = conn
        conn.start()
    }

    public func cancel() {
        teardownConnection()
        scannedPayload = nil
        phase = .idle
    }

    private func teardownConnection() {
        connection?.stop()
        connection = nil
    }

    // MARK: - Relay control frames

    private func handleControl(_ object: [String: Any]) {
        guard let type = object["type"] as? String, let payload = scannedPayload else { return }
        switch type {
        case "authed":
            sendPair(payload: payload)
        case "paired":
            handlePaired(object, payload: payload)
        case "pair-denied":
            handlePairDenied(object)
        default:
            break
        }
    }

    /// `RemotePairing.proof(secret:deviceSPKI:)` over THIS device's own key —
    /// never the Mac's, never anything read off the wire — is what proves to
    /// the Mac that whoever is asking to pair actually scanned the code it
    /// is showing (security review C2). The secret half never leaves this
    /// process except inside that MAC.
    private func sendPair(payload: PairingPayload) {
        guard let secretData = RemotePairing.data(fromBase64url: payload.secret) else {
            teardownConnection()
            phase = .refused("That pairing code is not in a format this app understands.")
            return
        }
        let proof = RemotePairing.proof(secret: secretData, deviceSPKI: signer.publicKeySPKI)
        connection?.send(control: [
            "type": "pair",
            "token": payload.token,
            "publicKey": signer.publicKeySPKI.base64EncodedString(),
            "name": Self.deviceName(),
            "proof": proof.base64EncodedString(),
        ])
        phase = .waiting
    }

    /// The relay's `paired` reply names a host id and key, but the relay is
    /// not trusted to say who that Mac is — only the QR code is. Both the id
    /// AND the key bytes must equal what was scanned, and the key must
    /// itself hash to that id (so a relay cannot pass a key/id pair that
    /// merely happen to both appear somewhere, but do not actually belong
    /// together). Any mismatch refuses and stores nothing.
    private func handlePaired(_ object: [String: Any], payload: PairingPayload) {
        guard
            let hostId = object["hostId"] as? String,
            let hostKeyB64 = object["hostPublicKey"] as? String,
            let spki = Data(base64Encoded: hostKeyB64),
            let expectedSPKI = Data(base64Encoded: payload.hostPublicKey),
            hostId == payload.hostId,
            spki == expectedSPKI,
            RemoteIdentity.peerId(forSPKI: spki) == hostId,
            let relayURL = URL(string: payload.relay)
        else {
            teardownConnection()
            phase = .refused("This Mac's reply did not match the code you scanned.")
            return
        }
        // The Mac does not send a display name over this reply — the name
        // the person gave this Mac on the confirm screen (`confirmedName`)
        // is the only one there is.
        let host = PairedHost(id: hostId, publicKeySPKI: spki, relay: relayURL,
                               name: confirmedName, pairedAt: now())
        store.add(host)
        phase = .paired(host)
    }

    private func handlePairDenied(_ object: [String: Any]) {
        teardownConnection()
        let reason = object["reason"] as? String ?? ""
        switch reason {
        case "token":
            phase = .refused("This pairing code expired or was already used. Ask for a new one.")
        case "host":
            phase = .refused("The Mac declined this pairing request.")
        default:
            phase = .refused("Pairing was declined.")
        }
    }

    /// This device's name, for the Mac's "Allow ‹name›?" prompt. The Mac
    /// sanitizes again on its side (security review L1), but a viewer should
    /// not send it junk in the first place — `RemotePairing.sanitizedDeviceName`
    /// is the one place both ends agree on what "junk" means (control
    /// characters and newlines stripped, capped at
    /// `RemotePairing.deviceNameLimit` characters).
    ///
    /// `Sources/MemtermRemoteApp` is Foundation/CryptoKit/MemtermRemoteKit
    /// only (the extension firewall), so this cannot reach `UIDevice.current.name`
    /// the way the real iOS app would want to — `ProcessInfo.hostName` is the
    /// nearest Foundation-only stand-in. Task 3's UI layer may replace this
    /// with the real device name without changing anything checked here.
    static func deviceName() -> String {
        RemotePairing.sanitizedDeviceName(ProcessInfo.processInfo.hostName)
    }
}
