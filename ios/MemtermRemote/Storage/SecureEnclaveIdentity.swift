import CryptoKit
import Foundation
import MemtermRemoteApp
import MemtermRemoteKit
import Security

/// This device's long-lived signing identity, backed by the Secure Enclave.
///
/// NOT compiled yet: `ios/` has no SwiftPM/Xcode target of its own in this
/// package (Task 3 adds the iOS app target that links it). It cannot be
/// built or run from this task, so it has not been exercised by `swift
/// test` — only read closely against the Secure Enclave / Keychain APIs it
/// calls. Task 3's first build is this file's first compile.
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
public final class SecureEnclaveIdentity: PhoneIdentityStoring {
    private static let service = "com.memterm.remote"
    private static let account = "device-identity"

    /// Resolved once per process: the Keychain holds either an Enclave
    /// wrapped blob or a software key's raw bytes, never both, and which one
    /// is current does not change mid-launch.
    private var cached: RemoteSigner?

    public init() {}

    public func identity() throws -> RemoteSigner {
        if let cached { return cached }
        let signer = try Self.loadOrCreate()
        cached = signer
        return signer
    }

    private static func loadOrCreate() throws -> RemoteSigner {
        if SecureEnclave.isAvailable {
            if let data = keychainRead(),
               let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
                return EnclaveSigner(key: key)
            }
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], nil)
            else { throw IdentityError.accessControl }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            keychainWrite(key.dataRepresentation)
            return EnclaveSigner(key: key)
        }
        // The simulator (and any other device CryptoKit reports as having no
        // Secure Enclave): fall back to an ordinary software P-256 key so
        // pairing and handshakes still work end to end there. Real devices
        // always take the branch above.
        if let data = keychainRead(), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return RemoteIdentity(privateKey: key)
        }
        let key = P256.Signing.PrivateKey()
        keychainWrite(key.rawRepresentation)
        return RemoteIdentity(privateKey: key)
    }

    enum IdentityError: Error {
        case accessControl
    }

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
