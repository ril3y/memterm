import CryptoKit
import Foundation
import MemtermRemoteApp
import MemtermRemoteKit
import Security

/// This device's long-lived signing identity, backed by the Secure Enclave.
///
/// Built by the iOS app target only, so `swift test` never exercises it:
/// its proof is the app building and running, plus the device checklist —
/// the Enclave itself is unavailable in a simulator, where the software
/// fallback below takes over. That fallback is compiled for the Simulator
/// only (`#if targetEnvironment(simulator)`): a device build that somehow
/// found no Enclave throws instead, because an exportable key would make this
/// type's whole claim silently false.
///
/// No biometry or passcode gate: this key signs the relay's challenge on
/// EVERY connect (`RelayConnection.handleFrame`'s `"challenge"` case), which
/// can happen the instant the app launches, long before a person has looked
/// at the screen. A Face ID/passcode prompt there would block the main
/// thread on user presence the app has no way to ask for off-screen, making
/// a merely-locked phone indistinguishable from a dead relay. So the access
/// control below is `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` with NO
/// `.biometryAny` / `.userPresence` / `.applicationPassword` flag — those are
/// the authentication gates; `.privateKeyUsage` is not one; it is what the
/// Secure Enclave requires on the access control of any key it is asked to
/// hold, biometry-gated or not; and ThisDeviceOnly keeps the key out of an
/// iCloud Keychain backup, where the Secure Enclave anchor would not go with
/// it.
/// `@MainActor`, so `cached` — mutable state reachable from a connection
/// callback — is single-threaded by construction rather than by the fact that
/// every call happens to come from the main queue today. `PhoneIdentityStoring`
/// is called from `AppModel`, which is itself main-actor.
@MainActor
public final class SecureEnclaveIdentity: PhoneIdentityStoring {
    private static let service = "com.memterm.remote"
    private static let account = "device-identity"

    /// Resolved once per process: the Keychain holds either an Enclave
    /// wrapped blob or a software key's raw bytes, never both, and which one
    /// is current does not change mid-launch.
    private var cached: RemoteSigner?

    /// Set when a stored identity could not be read and had to be replaced.
    /// Every Mac this device was paired with allows the OLD key, so they are
    /// all orphaned at once — and a person seeing only "handshake failed" has
    /// no way to know that re-pairing is the fix. `AppModel` reads this to say
    /// so. False on a first launch, where there was no identity to lose.
    public private(set) var replacedUnreadableIdentity = false

    public init() {}

    public func identity() throws -> RemoteSigner {
        if let cached { return cached }
        let signer = try loadOrCreate()
        cached = signer
        return signer
    }

    private func loadOrCreate() throws -> RemoteSigner {
        let stored = Self.keychainRead()
        if SecureEnclave.isAvailable {
            if let stored {
                if let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) {
                    return EnclaveSigner(key: key)
                }
                noteReplacedIdentity()
            }
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], nil)
            else { throw IdentityError.accessControl }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            Self.keychainWrite(key.dataRepresentation)
            return EnclaveSigner(key: key)
        }
        #if targetEnvironment(simulator)
        // The Simulator, which has no Secure Enclave: fall back to an ordinary
        // software P-256 key so pairing and handshakes still work end to end
        // there. Compiled for the Simulator ONLY, which is what makes the
        // branch's global constraint — the phone's identity key is generated
        // in the Secure Enclave and never leaves it — true by construction on
        // every build that can reach a real device, rather than true because
        // today's hardware happens never to take this path.
        if let stored {
            if let key = try? P256.Signing.PrivateKey(rawRepresentation: stored) {
                return RemoteIdentity(privateKey: key)
            }
            noteReplacedIdentity()
        }
        let key = P256.Signing.PrivateKey()
        Self.keychainWrite(key.rawRepresentation)
        return RemoteIdentity(privateKey: key)
        #else
        // A real device that reports no Secure Enclave: refuse rather than
        // silently minting an exportable key and claiming otherwise. There is
        // no iOS 17 device where this happens, so this is the constraint
        // stated in the type system, not a case anyone is expected to hit.
        throw IdentityError.noSecureEnclave
        #endif
    }

    /// The old key is gone either way — nothing here can recover it — so the
    /// app mints a replacement and says what happened, rather than looking
    /// like a device every Mac has quietly stopped trusting.
    private func noteReplacedIdentity() {
        replacedUnreadableIdentity = true
        NSLog("memterm: this device's stored identity could not be read; minting a new one. Paired Macs must be paired again.")
    }

    enum IdentityError: Error {
        case accessControl
        case noSecureEnclave
    }

    #if DEBUG
    /// Simulator/dev-only, and compiled out of every release build: installs
    /// a SPECIFIC raw P-256 private key into this device's identity slot
    /// before `identity()` is first called. The Simulator cannot pair by
    /// scanning a camera, so task 4's real end-to-end run pairs once outside
    /// the app (a headless tool speaking the same relay protocol
    /// `RemoteProbeClient` does) and then seeds BOTH halves of that pairing
    /// back in: the resulting `PairedHost` via `-memterm-seed-host`, and the
    /// exact key that earned it via this — so the Simulator app actually
    /// signs as the device the Mac really allowed in, rather than a fresh,
    /// unrecognized one. See `ios/CHECKLIST.md`.
    ///
    /// Always takes the software-key path: `SecureEnclave.isAvailable` is
    /// false on every Simulator, which is the only place this runs. A key
    /// that fails to parse is left alone rather than silently ignored into a
    /// fresh random identity, so a bad seed fails loudly as "no paired Macs"
    /// / a handshake the Mac refuses, not a confusing partial success.
    static func debugSeedIdentity(rawKeyBase64: String) {
        guard let raw = Data(base64Encoded: rawKeyBase64),
              (try? P256.Signing.PrivateKey(rawRepresentation: raw)) != nil
        else {
            NSLog("memterm: MEMTERM_SEED_IDENTITY_KEY_B64 did not decode as a P-256 raw key")
            return
        }
        keychainWrite(raw)
    }
    #endif

    /// Wraps a Secure Enclave key as a `RemoteSigner`. `RemoteIdentity` can't
    /// serve this role itself — it holds a `P256.Signing.PrivateKey` it can
    /// construct from raw bytes, which a Secure Enclave key has none of (the
    /// private key never leaves the Enclave). `RemoteIdentity.spki(forX963:)`
    /// is reused for the SPKI wrapping so the 26-byte DER header is written
    /// in exactly one place in this whole codebase.
    private struct EnclaveSigner: RemoteSigner {
        let key: SecureEnclave.P256.Signing.PrivateKey

        var publicKeySPKI: Data {
            RemoteIdentity.spki(forX963: key.publicKey.x963Representation)
        }

        var id: String {
            RemoteIdentity.peerId(forSPKI: publicKeySPKI)
        }

        /// Throws whatever the Enclave throws (locked device, cancelled
        /// prompt, timeout) — see `RemoteSigner.sign`'s doc comment. Nothing
        /// here is caught or papered over into an empty signature.
        func sign(_ data: Data) throws -> Data {
            try key.signature(for: data).rawRepresentation
        }
    }

    // MARK: - Keychain

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func keychainRead() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func keychainWrite(_ raw: Data) {
        // A pre-existing item (an old format, or a blob this launch could
        // not parse) is replaced outright: SecItemAdd on top of it would
        // only return errSecDuplicateItem.
        SecItemDelete(keychainQuery() as CFDictionary)
        var insert = keychainQuery()
        insert[kSecValueData as String] = raw
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insert[kSecAttrSynchronizable as String] = false
        SecItemAdd(insert as CFDictionary, nil)
    }
}
