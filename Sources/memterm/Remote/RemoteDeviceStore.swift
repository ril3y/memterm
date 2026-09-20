import CryptoKit
import Foundation
import MemtermCore

// Remote attach (decision doc 2026-09-19): the two pieces of state the host
// must survive a relaunch with — WHO WE ARE (the long-lived P-256 identity)
// and WHO WE TRUST (the paired devices' public keys).
//
// They live apart on purpose. The identity's private key is a secret, so it
// goes in the Keychain, where the OS guards it and a Developer ID-signed
// memterm keeps reading it across updates. The device list is not a secret —
// it is public keys and names the user typed — so it is a plain JSON file in
// the state dir, next to the journal, where the user can read it, back it up,
// or delete it. Neither ever touches the journal: FR-24 restore must not
// resurrect a trust decision.

// Security review 2026-09-20 (M2): the list is also MAC'd under a key
// derived from the Keychain identity (`RemoteDeviceSeal`). Re-deriving each
// id from its key stops a hand-edited id from redirecting trust, but it did
// nothing about a new ROW: any process running as the user could append its
// own public key and the next launch handed it a shell, with no Allow
// prompt ever shown. A file that does not verify is refused (logged, start
// empty) and left on disk untouched, so the user can still see what is in
// it.

/// One paired device, as stored on disk. `id` is derived from `publicKeySPKI`
/// (never accepted from the wire), so the file is self-verifying: a tampered
/// id cannot make us trust a different key.
struct PairedDevice: Codable, Equatable {
    var id: String
    var name: String
    /// DER SubjectPublicKeyInfo, base64. JSONEncoder's default Data strategy
    /// is base64, so the field is exactly that on disk.
    var publicKeySPKI: Data
    var pairedAt: Date
    var lastSeen: Date?
}

final class RemoteDeviceStore {

    /// Keychain coordinates. `kSecClassGenericPassword` with a fixed
    /// service/account pair is the plain, sync-free slot; no access group, so
    /// it stays inside this app's keychain partition.
    private static let keychainService = "com.memterm.remote"
    private static let keychainAccount = "host-identity"

    private let devicesURL: URL
    /// Probe and smoke runs must never read, write, or prompt against the
    /// FOUNDER's real Keychain and state dir: an automated run that pops a
    /// keychain dialog hangs CI, and one that writes a device file pollutes
    /// the machine. In those runs the identity is generated per launch and
    /// held in memory, and the device list starts (and stays) empty.
    private let ephemeral: Bool
    /// The identity for this launch, so repeated calls return one stable
    /// host id — and, since the device list's MAC key is derived from it,
    /// so verifying the list does not re-read the Keychain per call.
    private var identityCache: RemoteIdentity?

    private var storage: [PairedDevice] = []
    /// The list is loaded on FIRST USE, not in `init` (security review M2):
    /// verifying it needs the Keychain identity, and creating the store
    /// must not reach into the Keychain — an install with remote off never
    /// prompts and never stores a key. A device file that does not exist
    /// yet is simply an empty list, with no Keychain access at all.
    private var loaded = false

    var devices: [PairedDevice] {
        loadIfNeeded()
        return storage
    }

    init(devicesURL: URL = MemoryEngine.baseDir.appendingPathComponent("remote-devices.json"),
         ephemeral: Bool = ProbeSupport.isUIProbe || ProbeSupport.isSmoke) {
        self.devicesURL = devicesURL
        self.ephemeral = ephemeral
    }

    // MARK: - Identity

    /// The host's long-lived signing key: read from the Keychain, or
    /// generated and stored on first use.
    ///
    /// A Keychain blob is untrusted input (it can be a stale format, or
    /// garbage a user wrote with `security`), so a bad one is replaced rather
    /// than trapped on. That re-pairs every device, which is the honest
    /// outcome: without the old private key we cannot prove the old host id.
    func loadOrCreateIdentity() -> RemoteIdentity {
        if let identityCache { return identityCache }
        let identity = Self.resolveIdentity(ephemeral: ephemeral)
        identityCache = identity
        return identity
    }

    private static func resolveIdentity(ephemeral: Bool) -> RemoteIdentity {
        if ephemeral { return RemoteIdentity.generate() }
        if let raw = keychainRead(), let identity = try? RemoteIdentity(privateKeyRaw: raw) {
            return identity
        }
        let identity = RemoteIdentity.generate()
        keychainWrite(identity.privateKey.rawRepresentation)
        return identity
    }

    private static func keychainQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
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
        var query = keychainQuery()
        // AfterFirstUnlock, not WhenUnlocked: the mini is the host, and remote
        // attach has to keep working while the screen is locked — which is
        // most of the time it is useful. The key never syncs to iCloud.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecValueData as String] = raw
        // A pre-existing item (a half-written one, or a key we could not
        // parse) is replaced: SecItemAdd would only return errSecDuplicateItem.
        SecItemDelete(keychainQuery() as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    // MARK: - Devices

    func add(_ device: PairedDevice) {
        loadIfNeeded()
        // Re-pairing an existing device replaces its row (a browser that
        // cleared its storage comes back with a new key and the same name;
        // the same key coming back keeps one row, not two).
        storage.removeAll { $0.id == device.id }
        storage.append(device)
        save()
    }

    func remove(id: String) {
        loadIfNeeded()
        storage.removeAll { $0.id == id }
        save()
    }

    /// Records that a device just spoke to us, for the Settings list's
    /// "last seen" column. Not persisted on every envelope — only when the
    /// day's value actually changes — so a busy session doesn't rewrite the
    /// file per keystroke.
    func touch(id: String, at now: Date = Date()) {
        loadIfNeeded()
        guard let index = storage.firstIndex(where: { $0.id == id }) else { return }
        if let last = storage[index].lastSeen, now.timeIntervalSince(last) < 60 {
            storage[index].lastSeen = now
            return
        }
        storage[index].lastSeen = now
        save()
    }

    func device(id: String) -> PairedDevice? {
        devices.first { $0.id == id }
    }

    var allowedIds: [String] { devices.map(\.id) }

    // MARK: - Disk

    /// Reads and VERIFIES the device file, once per launch.
    ///
    /// A file whose MAC does not check out is refused outright: the list
    /// starts empty and the file is left exactly where it is, so nothing a
    /// tamperer wrote is trusted and nothing the user might want to look at
    /// is destroyed. Regenerating the host identity has the same effect,
    /// which is the honest failure mode — without the old private key we
    /// cannot prove the old host id either, so every device has to re-pair
    /// regardless.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard !ephemeral else { return }
        guard let data = try? Data(contentsOf: devicesURL) else { return }  // nothing paired yet
        let rows: [PairedDevice]
        switch RemoteDeviceSeal.decodeFile(data, identity: loadOrCreateIdentity(),
                                           as: PairedDevice.self) {
        case .rows(let decoded):
            rows = decoded
        case .unreadable:
            // Security re-review N5: the commonest way to land here is an
            // UNSIGNED list written before the seal existed, which decodes
            // as the wrong shape. Refusing it is correct — an
            // unauthenticated file must not be trusted — but the user's
            // devices have just silently vanished from Settings, so the
            // line names the file and says what to do about it.
            log("device list at \(devicesURL.path) is not in a readable format — it may predate "
                + "the signed format added in the 2026-09-20 security fixes. Starting with no "
                + "paired devices; pair them again from Settings ▸ Remote. The file is left in place.")
            return
        case .failedIntegrity:
            log("device list failed its integrity check; starting with no paired devices "
                + "(the file is left in place at \(devicesURL.lastPathComponent))")
            return
        }
        // The file is public, so re-derive every id from its key rather than
        // trusting the stored string: a hand-edited id must not be able to
        // redirect trust onto a different key. A row whose key no longer
        // parses as a P-256 SPKI is dropped, not kept as a device that could
        // never complete a handshake anyway.
        //
        // This runs AFTER the MAC check, over the rows exactly as decoded,
        // so a rewritten id fails verification rather than being quietly
        // corrected into a valid file.
        storage = rows.compactMap { device in
            guard Self.isValidSPKI(device.publicKeySPKI) else { return nil }
            var fixed = device
            fixed.id = RemoteIdentity.peerId(forSPKI: device.publicKeySPKI)
            return fixed
        }
    }

    /// Does this blob parse as the P-256 SubjectPublicKeyInfo the protocol
    /// uses? Every SPKI reaching the store comes off the wire, so it is
    /// checked once here instead of failing mysteriously at handshake time.
    static func isValidSPKI(_ spki: Data) -> Bool {
        (try? P256.Signing.PublicKey(derRepresentation: spki)) != nil
    }

    private func save() {
        guard !ephemeral else { return }
        try? FileManager.default.createDirectory(
            at: devicesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = RemoteDeviceSeal.encodeFile(storage, identity: loadOrCreateIdentity())
        else { return }
        try? data.write(to: devicesURL, options: .atomic)
    }

    private func log(_ message: String) {
        // Automated runs assert on exact probe output; remote chatter would
        // be noise there.
        guard !ProbeSupport.quiet else { return }
        print("memterm remote: \(message)")
    }
}
