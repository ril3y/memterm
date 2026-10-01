import Foundation

/// What the relay client needs from an identity: its peer id, its SPKI for
/// the `auth` frame, and a raw r‖s signature over the relay's nonce. The
/// Mac's Keychain-backed key and the phone's Secure Enclave key both fit.
public protocol RemoteSigner {
    var id: String { get }
    var publicKeySPKI: Data { get }
    func sign(_ data: Data) throws -> Data
}

// `RemoteIdentity.sign` matches this signature exactly, so the conformance
// body is empty. It is worth saying why that signature is throwing on BOTH
// implementations and not just the phone's: a Secure Enclave key fails for
// ordinary reasons (locked device, cancelled biometric prompt, timeout), while
// a software key on the Mac fails only on a hardware or entropy fault — but a
// non-throwing witness also satisfies a throwing requirement, so while
// `RemoteIdentity.sign` swallowed its own failure into `Data()` nothing
// downstream could ever observe one, `RemoteHost`'s guard against a Hello it
// could not sign was unreachable, and a 0-byte signature could still reach the
// wire. Throwing at the source is what makes the seam real rather than
// decorative.
extension RemoteIdentity: RemoteSigner {}
