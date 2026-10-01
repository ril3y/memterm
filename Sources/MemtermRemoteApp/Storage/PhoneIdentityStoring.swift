import Foundation
import MemtermRemoteKit

/// This device's long-lived signing identity. The app target backs this with
/// a Secure Enclave key, which is why `identity()` throws: on a phone,
/// signing fails for ordinary reasons (locked device, cancelled prompt), and
/// `RemoteSigner.sign` is throwing for exactly that reason.
public protocol PhoneIdentityStoring: AnyObject {
    func identity() throws -> RemoteSigner
}
