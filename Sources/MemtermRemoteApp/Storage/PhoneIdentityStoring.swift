import Foundation
import MemtermRemoteKit

/// This device's long-lived signing identity. The app target backs this with
/// a Secure Enclave key, which is why `identity()` throws: on a phone,
/// signing fails for ordinary reasons (locked device, cancelled prompt), and
/// `RemoteSigner.sign` is throwing for exactly that reason.
///
/// `@MainActor`: an implementation caches the resolved signer, and that cache
/// is reachable from a relay connection's callbacks. Every caller — `AppModel`,
/// `PairingFlow`, `HostSession` — is already main-actor, so this costs nothing
/// and makes "one thread touches that cache" true by construction instead of
/// true by habit.
@MainActor
public protocol PhoneIdentityStoring: AnyObject {
    func identity() throws -> RemoteSigner
}
