import Foundation

// The compiled-in 'serial' adapter (feature/serial UX stage): serial sessions
// are memterm's RECONNECTABLE restore class. The journaled adapter_state holds
// the port's stable identity + line settings; restore surfaces the standard
// consent-gated ⌘R offer, and the gesture performs a RECONNECT ACTION — it
// never composes or types a shell command, so the FR-30 denylist path is
// untouched by design (Adapters.resumeOffer returns nil for "serial": there
// is no command to offer, and that is asserted in tests).
//
// Consent story: opening a device requires the same explicit gesture as every
// other restore offer. A restored serial pane prints "was connected: … —
// press ⌘R to reconnect" and waits; only ⌘R (or an equally explicit UI
// action) opens the fd. The one deliberate exception is a LIVE session whose
// device is unplugged and replugged: the user's original open is standing
// consent for that session, so the pane auto-reopens on hotplug return
// (tio-style) — but never across a restore boundary.

public enum SerialAdapter {

    /// The adapter name journaled in pane_snapshot.adapter.
    public static let name = "serial"

    // adapter_state keys.
    public static let pathKey = "path"
    public static let identityKey = "identity"
    public static let settingsKey = "settings"
    public static let labelKey = "label"
    public static let txKey = "tx"
    public static let echoKey = "echo"

    /// Everything the ⌘R gesture needs to bring a serial pane back.
    public struct ReconnectOffer: Equatable {
        public let path: String
        public let identity: String
        public let label: String
        public let settings: SerialSettings
        public let txLineEnding: SerialLineEnding
        public let localEcho: Bool

        public init(path: String, identity: String, label: String,
                    settings: SerialSettings, txLineEnding: SerialLineEnding,
                    localEcho: Bool) {
            self.path = path
            self.identity = identity
            self.label = label
            self.settings = settings
            self.txLineEnding = txLineEnding
            self.localEcho = localEcho
        }

        /// "usbserial-0001 @ 115200-8N1" — the human name of the session.
        public var displayName: String {
            "\(SerialAdapter.shortName(forPath: path)) @ \(settings.compactString)"
        }
    }

    /// adapter_state for the journal. All strings — the pane_snapshot state
    /// column is a flat string map.
    public static func journalState(path: String, identity: String, label: String,
                                    settings: SerialSettings,
                                    txLineEnding: SerialLineEnding,
                                    localEcho: Bool) -> [String: String] {
        [pathKey: path,
         identityKey: identity,
         labelKey: label,
         settingsKey: settings.compactString,
         txKey: txLineEnding.rawValue,
         echoKey: localEcho ? "1" : "0"]
    }

    /// Parses journaled adapter_state back into an offer. nil when the state
    /// is malformed (missing path or unparseable settings) — a broken row
    /// yields no offer, never a mis-configured open.
    public static func reconnectOffer(from state: [String: String]) -> ReconnectOffer? {
        guard let path = state[pathKey], !path.isEmpty,
              let settingsString = state[settingsKey],
              let settings = SerialSettings.parse(settingsString) else { return nil }
        let tx = state[txKey].flatMap { SerialLineEnding(rawValue: $0) } ?? .crlf
        return ReconnectOffer(path: path,
                              identity: state[identityKey] ?? "path:\(path)",
                              label: state[labelKey] ?? shortName(forPath: path),
                              settings: settings,
                              txLineEnding: tx,
                              localEcho: state[echoKey] == "1")
    }

    /// Short port name for titles/offers: "/dev/cu.usbserial-0001" →
    /// "usbserial-0001" (the "cu." prefix is noise once the node is picked).
    public static func shortName(forPath path: String) -> String {
        let full = (path as NSString).lastPathComponent
        for prefix in ["cu.", "tty."] where full.hasPrefix(prefix) {
            let trimmed = String(full.dropFirst(prefix.count))
            if !trimmed.isEmpty { return trimmed }
        }
        return full
    }

    /// Pane title: "usbserial-0001 @ 115200".
    public static func paneTitle(path: String, baud: Int) -> String {
        "\(shortName(forPath: path)) @ \(baud)"
    }
}
