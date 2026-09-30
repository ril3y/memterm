import Foundation

/// What the relay client needs from an identity: its peer id, its SPKI for
/// the `auth` frame, and a raw r‖s signature over the relay's nonce. The
/// Mac's Keychain-backed key and the phone's Secure Enclave key both fit.
public protocol RemoteSigner {
    var id: String { get }
    var publicKeySPKI: Data { get }
    func sign(_ data: Data) throws -> Data
}

// RemoteIdentity's existing non-throwing `sign` satisfies this throwing
// requirement unchanged (a non-throwing function is a valid witness for a
// throwing requirement), so the conformance body stays empty. On the Mac
// that sign never actually throws — but a Secure Enclave key on the phone
// fails for ordinary reasons (locked device, cancelled biometric prompt,
// timeout), and this seam is what lets that failure be reported instead of
// silently becoming an empty signature on the wire.
extension RemoteIdentity: RemoteSigner {}
