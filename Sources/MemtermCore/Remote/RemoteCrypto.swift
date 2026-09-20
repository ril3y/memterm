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
        Self.id(forSPKI: publicKeySPKI)
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
    static func id(forSPKI spki: Data) -> String {
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

/// The two-message handshake. Each side offers a fresh ephemeral ECDH key
/// signed by its long-lived identity, so forward secrecy comes from the
/// ephemeral and authentication from the signature.
public enum RemoteHandshake {

    public struct Hello: Equatable {
        /// The ephemeral P-256 public key, x9.63 uncompressed (65 bytes).
        public var ephemeralRaw: Data
        /// Raw r‖s over `ephemeralRaw`, by the sender's identity key.
        public var signature: Data

        public init(ephemeralRaw: Data, signature: Data) {
            self.ephemeralRaw = ephemeralRaw
            self.signature = signature
        }
    }

    public static func makeHello(identity: RemoteIdentity) -> (Hello, P256.KeyAgreement.PrivateKey) {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let raw = ephemeral.publicKey.x963Representation
        return (Hello(ephemeralRaw: raw, signature: identity.sign(raw)), ephemeral)
    }

    /// Both arguments come off the wire, so every parse failure is just
    /// "not verified" rather than an error to distinguish.
    public static func verifyHello(_ hello: Hello, peerSPKI: Data) -> Bool {
        guard
            let peerRaw = RemoteIdentity.x963(fromSPKI: peerSPKI),
            let peerKey = try? P256.Signing.PublicKey(x963Representation: peerRaw),
            let signature = try? P256.Signing.ECDSASignature(rawRepresentation: hello.signature)
        else { return false }
        return peerKey.isValidSignature(signature, for: hello.ephemeralRaw)
    }

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
public final class RemoteSessionKeys {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
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
    public func seal(_ plaintext: Data) throws -> Data {
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
