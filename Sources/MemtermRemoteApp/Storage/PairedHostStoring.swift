import Foundation

/// Where paired Macs live. The app target backs this with the Keychain; the
/// tests back it with an array.
public protocol PairedHostStoring: AnyObject {
    func load() -> [PairedHost]
    func add(_ host: PairedHost)
    func remove(id: String)
}
