import Foundation
import MemtermRemoteKit

/// A Mac this device has been allowed into, as stored on the phone.
///
/// `publicKeySPKI` is the ONLY source of the host's identity for the key
/// schedule: every handshake verifies against these bytes, never against a
/// `hostId` a relay sent. `relay` is the relay this pairing happened over,
/// which is not necessarily the one the page came from — the QR names it.
public struct PairedHost: Codable, Equatable, Identifiable {
    public var id: String
    public var publicKeySPKI: Data
    public var relay: URL
    public var name: String
    public var pairedAt: Date

    public init(id: String, publicKeySPKI: Data, relay: URL, name: String, pairedAt: Date) {
        self.id = id; self.publicKeySPKI = publicKeySPKI
        self.relay = relay; self.name = name; self.pairedAt = pairedAt
    }
}
