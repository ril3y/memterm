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

    /// Long enough for a real `wss://host:port` relay, short enough that it
    /// cannot push the rest of the confirm screen's text out of view.
    public static let relayDisplayLimit = 64

    /// The relay as the confirm screen shows it. Every field of this payload
    /// came out of a QR code that may not be the one on this person's Mac, and
    /// the confirm screen is the one place they are asked to make a trust
    /// decision — so the relay is bounded and stripped of anything that could
    /// forge a second line of text before it is displayed, by the same
    /// sanitizer and for the same reason as a device name (security review
    /// L1). `hostId` needs no equivalent: `PairingFlow.scanned` refuses a
    /// payload whose `hostId` is not the base32 hash of its own
    /// `hostPublicKey`, so by the time a payload can be displayed at all, its
    /// id is provably 16 characters of `[a-z2-7]`.
    public var relayForDisplay: String {
        RemotePairing.sanitizedDeviceName(relay, fallback: "an unnamed relay",
                                          limit: Self.relayDisplayLimit)
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
    /// What to call this device in the Mac's "Allow ‹name›?" prompt, read
    /// fresh at each `pair` (a person can rename their phone between
    /// attempts). The result is sanitized here, not trusted from the caller.
    private let deviceName: () -> String

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

    /// - Parameter deviceName: This device's name for the Mac's Allow prompt.
    ///   Defaults to the Foundation-only stand-in this module can reach on its
    ///   own; the iOS app passes `UIDevice.current.name`, which is the name the
    ///   person actually recognises. The UIKit call stays in the app target, so
    ///   the extension firewall over this module is untouched.
    public init(signer: RemoteSigner, store: PairedHostStoring,
                makeConnection: @escaping (URL, RelayConnection.Events) -> RelayConnection,
                now: @escaping () -> Date = Date.init,
                deviceName: @escaping () -> String = PairingFlow.foundationDeviceName) {
        self.signer = signer
        self.store = store
        self.makeConnection = makeConnection
        self.now = now
        self.deviceName = deviceName
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
        // The id and the key must belong together, checked here rather than
        // only later in `handlePaired`. Two reasons, and the second is the one
        // that made this worth a guard of its own: a code whose id and key do
        // not match cannot possibly pair, so refusing now saves dialling a
        // relay for it at all; and the confirm screen puts `hostId` in front
        // of the person as the Mac they are about to trust, so that id has to
        // be provably the base32 hash of this very key — 16 characters of
        // `[a-z2-7]` — and not arbitrary text a QR code chose.
        guard RemoteIdentity.peerId(forSPKI: hostKeySPKI) == payload.hostId else {
            phase = .refused("That pairing code's Mac name and key do not match each other.")
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
        // Same sanitizer the Mac applies to a device's name: bounded, and
        // stripped of anything that could forge a second line of text. This
        // one is typed by the person rather than sent by a peer, but it still
        // lands in a Keychain item and in a list row.
        confirmedName = RemotePairing.sanitizedDeviceName(name, fallback: "Mac")

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
            // The Mac sanitizes again on its side (security review L1), but a
            // viewer should not send it junk in the first place — and the name
            // now comes from outside this module, so sanitizing here is what
            // keeps that true. `RemotePairing.sanitizedDeviceName` is the one
            // place both ends agree on what "junk" means: control characters
            // and newlines stripped, capped at `RemotePairing.deviceNameLimit`.
            "name": RemotePairing.sanitizedDeviceName(deviceName()),
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
        // This attempt is over: the pairing socket has nothing left to carry,
        // and leaving it open with `scannedPayload` still live meant every
        // further `paired` frame was re-processed and re-stored. Harmless
        // given the re-validation above and the store's upsert, but a
        // connection with no remaining purpose should not stay open.
        teardownConnection()
        scannedPayload = nil
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

    /// The default `deviceName`: `Sources/MemtermRemoteApp` is
    /// Foundation/CryptoKit/MemtermRemoteKit only (the extension firewall), so
    /// it cannot reach `UIDevice.current.name` itself, and
    /// `ProcessInfo.hostName` is the nearest Foundation-only stand-in. On iOS
    /// that is not a name anyone recognises, which matters: the Allow prompt
    /// and the key-id callout are the person's two defences at pairing time,
    /// and a name they do not recognise makes the prompt harder to act on
    /// correctly. So the real app injects the real name through
    /// `init(…deviceName:)` — this is only what a test, or a caller with no UI
    /// to ask, falls back to.
    /// `nonisolated`: this reads one process-wide value and touches nothing of
    /// the flow's, and it is used as a default argument — which has to be a
    /// plain `() -> String`, not a main-actor-isolated one.
    public nonisolated static func foundationDeviceName() -> String {
        ProcessInfo.processInfo.hostName
    }
}
