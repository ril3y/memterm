import CryptoKit
import Foundation

// Integrity for the host's paired-device list (security review 2026-09-20,
// M2). The list is public data — names and public keys — so it is not
// encrypted and stays a readable JSON file the user can inspect. What it
// was missing is a reason to believe the app wrote it.
//
// Without one, any process running as the same user could append its own
// public key to `remote-devices.json`, and the next launch would hand that
// key a shell with no Allow prompt ever shown. That turns one-shot local
// code execution into durable, network-reachable, reboot-surviving access.
//
// The fix is a MAC under a key only the Keychain identity can derive. An
// attacker who can already read the Keychain item has host impersonation
// anyway, so this buys exactly what it should: a file edit alone is no
// longer enough. Regenerating the identity invalidates every row, which is
// the honest failure mode — without the old private key we cannot prove the
// old host id either.

/// Seals and verifies the canonical JSON of the paired-device list under a
/// key derived from the host identity.
public enum RemoteDeviceSeal {

    /// HKDF `info`, so this key cannot collide with the session keys the
    /// same identity's ECDH output feeds (`memterm-remote-v1` ‖ ids).
    public static let info = "memterm-remote-v1:devices"

    /// HKDF-SHA256 over the identity's raw private key. The private key is
    /// the input keying material rather than the MAC key itself so that a
    /// leak of this derived key does not hand over the signing key.
    public static func key(identity: RemoteIdentity) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: identity.privateKey.rawRepresentation),
            salt: Data(),
            info: Data(info.utf8),
            outputByteCount: 32)
    }

    /// The `mac` field's value: base64 of HMAC-SHA256 over `canonicalJSON`.
    ///
    /// The caller passes a CANONICAL encoding (sorted keys, no whitespace)
    /// rather than the bytes on disk, so reformatting the file by hand does
    /// not break the seal but changing any value does.
    public static func seal(canonicalJSON: Data, identity: RemoteIdentity) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: canonicalJSON, using: key(identity: identity)))
            .base64EncodedString()
    }

    /// Constant-time verification. A missing, unparseable or wrong MAC is
    /// simply `false` — the caller's job is to refuse the file, not to
    /// distinguish how it was tampered with.
    public static func verify(canonicalJSON: Data, mac: String, identity: RemoteIdentity) -> Bool {
        guard let candidate = Data(base64Encoded: mac) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            candidate, authenticating: canonicalJSON, using: key(identity: identity))
    }
}
