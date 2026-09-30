import Foundation

/// What the relay client needs from an identity: its peer id, its SPKI for
/// the `auth` frame, and a raw r‖s signature over the relay's nonce. The
/// Mac's Keychain-backed key and the phone's Secure Enclave key both fit.
public protocol RemoteSigner {
    var id: String { get }
    var publicKeySPKI: Data { get }
    func sign(_ data: Data) -> Data
}

extension RemoteIdentity: RemoteSigner {}
