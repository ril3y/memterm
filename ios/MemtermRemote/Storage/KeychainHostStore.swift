import Foundation
import MemtermRemoteKit
import Security

/// Where paired Macs live on the phone: one Keychain item per host, keyed by
/// `hostId`, value the JSON-encoded `PairedHost`.
///
/// NOT compiled yet (same note as `SecureEnclaveIdentity`): `ios/` has no
/// build target in this package until Task 3 adds the iOS app target. Read
/// closely against the Keychain APIs it calls, but not yet exercised by
/// `swift test` or any build.
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and never synchronizable —
/// the same choice `SecureEnclaveIdentity` makes and for a related reason:
/// a paired host's public key is what every handshake verifies against (see
/// `PairedHost`'s doc comment), so it must not silently reappear on another
/// one of the person's devices via iCloud Keychain, paired with a Mac that
/// device never went through the QR flow for.
public final class KeychainHostStore: PairedHostStoring {
    private static let service = "com.memterm.remote.hosts"

    public init() {}

    public func load() -> [PairedHost] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let rows = items as? [Data]
        else { return [] }
        let decoder = JSONDecoder()
        return rows.compactMap { try? decoder.decode(PairedHost.self, from: $0) }
    }

    public func add(_ host: PairedHost) {
        guard let data = try? JSONEncoder().encode(host) else { return }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: host.id,
        ]
        // Re-pairing the same host (a fresh QR scan after, say, clearing the
        // Mac's device list) replaces its row rather than erroring on
        // `errSecDuplicateItem`.
        SecItemDelete(identity as CFDictionary)
        var insert = identity
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insert[kSecAttrSynchronizable as String] = false
        SecItemAdd(insert as CFDictionary, nil)
    }

    public func remove(id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
