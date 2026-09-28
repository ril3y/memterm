import CryptoKit
import Foundation

// End-to-end crypto between the memterm host and a phone's browser
// (decision doc 2026-09-19). The relay never sees plaintext: it routes
// `RemoteEnvelope`s whose payload is a record sealed here.
//
// The counterparty is WebCrypto, so every byte format below is a contract,
// not an implementation detail:
//   - public keys travel as DER SubjectPublicKeyInfo (WebCrypto's "spki"),
//   - signatures as raw r‖s (WebCrypto's ECDSA format, never DER),
//   - keys come from one HKDF-SHA256 expansion split by direction,
//   - records are nonce ‖ ciphertext ‖ tag with a per-direction counter.
// `Tests/vectors/remote-crypto-vectors.json` pins the schedule and the first
// record; the web client's suite reads that same file.

public enum RemoteCryptoError: Error, Equatable {
    /// A `Hello` was not signed by the identity we expect to be talking to.
    case badSignature
    /// A record's nonce was not the next counter this direction expects —
    /// a repeat, a reorder, or an injection.
    case replay
    /// Wrong length, unparseable key material, or a failed GCM tag.
    case malformed
}

/// The long-lived P-256 signing key. The host keeps it in the Keychain as
/// `privateKey.rawRepresentation`; the phone keeps its own in IndexedDB.
public struct RemoteIdentity {
    public let privateKey: P256.Signing.PrivateKey

    /// DER SubjectPublicKeyInfo: the fixed id-ecPublicKey/prime256v1 header
    /// followed by the uncompressed point. This is what the relay stores and
    /// what peers pin.
    public var publicKeySPKI: Data {
        Self.spki(forX963: privateKey.publicKey.x963Representation)
    }

    /// The peer id the relay addresses us by. `relay/src/auth.ts` derives it
    /// from the same SPKI bytes with the same encoder, so the two must agree
    /// exactly or the phone cannot reach this host.
    public var id: String {
        Self.peerId(forSPKI: publicKeySPKI)
    }

    public init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    /// Restores an identity from Keychain bytes. The blob is untrusted
    /// input, so a wrong length throws rather than trapping.
    public init(privateKeyRaw: Data) throws {
        do {
            self.privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        } catch {
            throw RemoteCryptoError.malformed
        }
    }

    public static func generate() -> RemoteIdentity {
        RemoteIdentity(privateKey: P256.Signing.PrivateKey())
    }

    /// ECDSA P-256 with SHA-256 in WebCrypto's raw format: 64 bytes r‖s.
    /// CryptoKit's `rawRepresentation` is already that layout — the DER form
    /// would be rejected by `crypto.subtle.verify`.
    public func sign(_ data: Data) -> Data {
        // P256 signing only fails on a hardware/entropy fault, and there is
        // no sensible recovery at a call site that must produce a Hello.
        guard let signature = try? privateKey.signature(for: data) else { return Data() }
        return signature.rawRepresentation
    }

    // MARK: - SPKI

    /// DER prefix for `SEQUENCE { AlgorithmIdentifier(id-ecPublicKey,
    /// prime256v1), BIT STRING }` sized for a 65-byte uncompressed point.
    /// Fixed for every P-256 key, so wrapping is a concatenation.
    static let spkiHeader = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    static let x963Length = 65
    static let spkiLength = spkiHeader.count + x963Length

    static func spki(forX963 x963: Data) -> Data {
        spkiHeader + x963
    }

    /// Unwraps an SPKI back to the raw point. Peer SPKIs arrive over the
    /// network, so anything that is not our exact 91-byte shape is rejected.
    static func x963(fromSPKI spki: Data) -> Data? {
        guard spki.count == spkiLength, spki.prefix(spkiHeader.count) == spkiHeader else { return nil }
        return Data(spki.suffix(x963Length))
    }

    /// base32(sha256(spki))[0..<16], lower-case RFC 4648 alphabet, unpadded —
    /// byte-for-byte what `relay/src/auth.ts` computes.
    ///
    /// Public because callers MUST be able to name a peer by its *verified*
    /// key rather than by anything the peer claims: see the warning on
    /// `RemoteHandshake.deriveKeys`.
    public static func peerId(forSPKI spki: Data) -> String {
        String(base32(Data(SHA256.hash(data: spki))).prefix(16))
    }

    static func base32(_ bytes: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var bits = 0
        var value = 0
        var out = ""
        out.reserveCapacity((bytes.count * 8 + 4) / 5)
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }
}

/// Pairing-token handling: the split token and the proof that binds a
/// device's key to the QR code the user actually showed it.
///
/// Security review 2026-09-20 (C2): the relay used to be handed the WHOLE
/// pairing token, and `pair-request` carried nothing tying the device's
/// public key to whoever consumed that token. A hostile relay could
/// therefore substitute its own key inside a genuine request, or mint an
/// unsolicited request while the QR sheet was open, and one Allow click
/// gave it a shell.
///
/// So the 32 random bytes are split:
///   - bytes[0..<16] → the ROUTING token, base64url, the only half the
///     relay ever sees. It is a map key, nothing more.
///   - bytes[16..<32] → the pair SECRET, which never leaves the QR code.
/// The device proves it scanned the code by sending
/// `HMAC-SHA256(secret, "memterm-remote-v1:pair" ‖ deviceSPKI)`, and the
/// host recomputes that over the SPKI it was actually sent, before any
/// prompt. The relay can neither compute the MAC for a key of its own nor
/// mint a request at all.
public enum RemotePairing {

    /// Domain separation, and the reason a signature or MAC gathered
    /// elsewhere in this protocol can never be presented as a pair proof.
    /// The web client prepends the identical bytes.
    public static let proofLabel = "memterm-remote-v1:pair"

    /// 16 bytes of base64url with no padding. The relay rejects anything
    /// else outright, so a token is a fixed-size string, not an arbitrary
    /// one an attacker can grow (security review H1).
    public static let routingTokenLength = 22
    public static let tokenBytes = 32
    static let halfBytes = 16

    /// Splits freshly minted randomness into the half the relay routes on
    /// and the half only the QR code carries. Anything but 32 bytes is a
    /// programming error at the call site, so it yields nil rather than
    /// silently pairing on a short secret.
    public static func split(_ bytes: Data) -> (routingToken: String, secret: Data)? {
        guard bytes.count == tokenBytes else { return nil }
        let routing = Data(bytes.prefix(halfBytes))
        let secret = Data(bytes.suffix(halfBytes))
        return (base64url(routing), secret)
    }

    /// The exact bytes the MAC covers. `deviceSPKI` is the DER
    /// SubjectPublicKeyInfo as it travels on the wire — the same bytes the
    /// host hashes into the device id, so a proof can only ever vouch for
    /// the one key it was computed over.
    public static func proofPayload(deviceSPKI: Data) -> Data {
        Data(proofLabel.utf8) + deviceSPKI
    }

    public static func proof(secret: Data, deviceSPKI: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: proofPayload(deviceSPKI: deviceSPKI),
            using: SymmetricKey(data: secret)))
    }

    /// Constant-time comparison (CryptoKit's own), so a hostile relay
    /// cannot learn the expected MAC one byte at a time by timing the
    /// host's silent denials.
    public static func isValidProof(_ candidate: Data, secret: Data, deviceSPKI: Data) -> Bool {
        guard !secret.isEmpty else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            candidate,
            authenticating: proofPayload(deviceSPKI: deviceSPKI),
            using: SymmetricKey(data: secret))
    }

    /// RFC 4648 §5 without padding — what the QR payload's `token` and
    /// `secret` fields carry, and what the relay's token validation
    /// expects.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The length the "Allow ‹name›?" prompt shows a device name at.
    public static let deviceNameLimit = 32

    /// A device name is chosen by whoever is asking to be trusted, and it
    /// is interpolated into that prompt (security review L1). A name like
    /// `iPhone\n\nRoutine macOS prompt — click Allow` could fabricate its
    /// own instructions inside the alert, so control characters and
    /// newlines are stripped and the rest is capped short enough that it
    /// cannot push the real text off the dialog.
    ///
    /// Names are labels, never identity: the key is what gets stored, and
    /// the prompt shows the key id alongside.
    public static func sanitizedDeviceName(_ raw: String) -> String {
        // `.newlines` as well as `.controlCharacters`: the latter covers
        // CR/LF and the C0/C1 ranges, the former adds U+2028/U+2029, which
        // AppKit also breaks a line on.
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        let stripped = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { !forbidden.contains($0) }))
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(deviceNameLimit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? "Device" : capped
    }

    /// The inverse. Untrusted input (it arrives inside a QR payload the
    /// host minted but a device echoes), so anything unparseable is nil.
    public static func data(fromBase64url string: String) -> Data? {
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = standard.count % 4
        if remainder != 0 { standard.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: standard)
    }
}

/// The two-message handshake. Each side offers a fresh ephemeral ECDH key
/// signed by its long-lived identity, so forward secrecy comes from the
/// ephemeral and authentication from the signature.
public enum RemoteHandshake {

    public struct Hello: Equatable {
        /// The ephemeral P-256 public key, x9.63 uncompressed (65 bytes).
        public var ephemeralRaw: Data
        /// Raw r‖s over `helloSigningLabel ‖ ephemeralRaw`, by the sender's
        /// identity key.
        public var signature: Data

        public init(ephemeralRaw: Data, signature: Data) {
            self.ephemeralRaw = ephemeralRaw
            self.signature = signature
        }
    }

    /// Domain separation for the identity signature. Without a prefix, the
    /// same identity key signs bare byte strings in two protocols at once —
    /// here a 65-byte point, and at the relay a 32-byte auth nonce — so a
    /// signature gathered in one could be presented as the other. Prefixing
    /// makes the two input spaces disjoint. The web client must prepend the
    /// identical bytes, which is why this is public.
    public static let helloSigningLabel = "memterm-remote-v1:hello"

    /// The exact bytes an identity signs for a `Hello`.
    public static func helloSigningPayload(ephemeralRaw: Data) -> Data {
        Data(helloSigningLabel.utf8) + ephemeralRaw
    }

    public static func makeHello(identity: RemoteIdentity) -> (Hello, P256.KeyAgreement.PrivateKey) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let raw = ephemeral.publicKey.x963Representation
        let signature = identity.sign(helloSigningPayload(ephemeralRaw: raw))
        return (Hello(ephemeralRaw: raw, signature: signature), ephemeral)
    }

    /// Both arguments come off the wire, so every parse failure is just
    /// "not verified" rather than an error to distinguish.
    public static func verifyHello(_ hello: Hello, peerSPKI: Data) -> Bool {
        guard
            let peerRaw = RemoteIdentity.x963(fromSPKI: peerSPKI),
            let peerKey = try? P256.Signing.PublicKey(x963Representation: peerRaw),
            let signature = try? P256.Signing.ECDSASignature(rawRepresentation: hello.signature)
        else { return false }
        return peerKey.isValidSignature(signature, for: helloSigningPayload(ephemeralRaw: hello.ephemeralRaw))
    }

    /// - Warning: `hostId` and `deviceId` bind the session to two named
    ///   identities, which is what stops an unknown-key-share: an attacker
    ///   who relays our ephemeral cannot make both sides agree on who they
    ///   are talking to. That only holds if the caller computes BOTH ids
    ///   with `RemoteIdentity.peerId(forSPKI:)` over identity keys it has
    ///   already verified — its own, and the peer's, the same SPKI that just
    ///   passed `verifyHello`. Never take either id from a field on the
    ///   wire: a self-declared id is a value the attacker chooses, and
    ///   feeding it here silently removes the binding.
    public static func deriveKeys(
        myEphemeral: P256.KeyAgreement.PrivateKey,
        peerEphemeralRaw: Data,
        hostId: String,
        deviceId: String,
        iAmHost: Bool
    ) throws -> RemoteSessionKeys {
        guard
            let peerKey = try? P256.KeyAgreement.PublicKey(x963Representation: peerEphemeralRaw),
            let shared = try? myEphemeral.sharedSecretFromKeyAgreement(with: peerKey)
        else { throw RemoteCryptoError.malformed }
        // The raw bytes are the 32-byte x-coordinate — the same IKM WebCrypto
        // hands to HKDF after `deriveBits`. Routing through the Data seam
        // keeps one schedule for production and for the vectors.
        let ikm = shared.withUnsafeBytes { Data($0) }
        return deriveKeys(sharedSecret: ikm, hostId: hostId, deviceId: deviceId, iAmHost: iAmHost)
    }

    /// The key schedule on its own, so the shared vectors can pin it without
    /// a live ECDH: one 64-byte HKDF expansion split by direction.
    public static func deriveKeys(
        sharedSecret: Data,
        hostId: String,
        deviceId: String,
        iAmHost: Bool
    ) -> RemoteSessionKeys {
        let info = Data(Self.label.utf8) + Data(hostId.utf8) + Data(deviceId.utf8)
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sharedSecret),
            salt: Data(),
            info: info,
            outputByteCount: 64
        ).withUnsafeBytes { Data($0) }

        let hostToClient = Data(okm.prefix(32))
        let clientToHost = Data(okm.suffix(32))
        return RemoteSessionKeys(
            sendKey: iAmHost ? hostToClient : clientToHost,
            receiveKey: iAmHost ? clientToHost : hostToClient
        )
    }

    /// Bumping this version string reshuffles every key, which is the point:
    /// a host and a phone on different protocol versions cannot talk.
    static let label = "memterm-remote-v1"
}

/// One direction-split AES-256-GCM session. Stateful by design — the
/// counters are the replay defence — so it is a class, owned by whatever
/// owns the connection.
///
/// Thread safety: safe to call `seal` and `open` from any thread, including
/// concurrently. Both take an internal lock covering the whole operation,
/// not just the counter bump. That is a correctness requirement, not a
/// convenience: a read-modify-write race on `sendCounter` would hand the
/// same nonce to two records under one AES-GCM key, which leaks the XOR of
/// the two plaintexts and the GHASH authentication key, letting an attacker
/// forge records. The host writes PTY output from a reader thread while the
/// UI can seal a control message, so this is a real interleaving.
///
/// The lock also serialises records against their own counters, so the
/// nonce a record carries is always the one its sealing incremented past.
public final class RemoteSessionKeys: @unchecked Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let lock = NSLock()
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    /// The sealing key, for the shared vectors to record. Not part of the
    /// public surface: nothing in the app should need raw key bytes.
    var sendKeyBytes: Data { sendKey.withUnsafeBytes { Data($0) } }

    init(sendKey: Data, receiveKey: Data) {
        self.sendKey = SymmetricKey(data: sendKey)
        self.receiveKey = SymmetricKey(data: receiveKey)
    }

    /// 12-byte GCM nonce: four zero bytes then the big-endian counter. Each
    /// direction has its own key, so counters may overlap between them.
    static func nonceBytes(counter: UInt64) -> Data {
        var data = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Record = nonce (12) ‖ ciphertext ‖ tag (16), i.e. GCM's combined box.
    ///
    /// The lock spans the seal, not just the counter bump: reading the
    /// counter and consuming it must be one atomic step or two threads
    /// reuse a nonce.
    public func seal(_ plaintext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard
            let nonce = try? AES.GCM.Nonce(data: Self.nonceBytes(counter: sendCounter)),
            let box = try? AES.GCM.seal(plaintext, using: sendKey, nonce: nonce),
            let combined = box.combined
        else { throw RemoteCryptoError.malformed }
        sendCounter &+= 1
        return combined
    }

    /// Accepts only the next counter this direction expects. A repeat, a
    /// reorder, or an injected record is `.replay`; a failed tag or a
    /// truncated record is `.malformed`. Neither failure advances the
    /// counter, so the genuine next record still opens afterwards.
    public func open(_ record: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard record.count >= 12 + 16 else { throw RemoteCryptoError.malformed }
        guard Data(record.prefix(12)) == Self.nonceBytes(counter: receiveCounter) else {
            throw RemoteCryptoError.replay
        }
        guard
            let box = try? AES.GCM.SealedBox(combined: record),
            let plaintext = try? AES.GCM.open(box, using: receiveKey)
        else { throw RemoteCryptoError.malformed }
        receiveCounter &+= 1
        return plaintext
    }
}
