import Foundation

// Serial footer bar model (founder ask: a slim status strip on every serial
// pane). All the logic the strip needs that can be a pure function lives here
// per the TESTING.md placement rule — counter accumulation, human-unit byte
// formatting, the ≤4 Hz UI-update throttle, the state-dot mapping, and the
// settings-summary strings. The AppKit face (SerialFooterView) is thin: it
// paints what this model says and forwards clicks.
public struct SerialFooterModel: Equatable {

    /// State dot: ● green connected / ● orange reconnecting (the liveness /
    /// hotplug machinery's `awaitingDeviceReturn`) / ● gray disconnected
    /// (restored pane or failed open, waiting on the ⌘R consent gesture).
    public enum LinkState: Equatable {
        case connected
        case reconnecting
        case disconnected
    }

    /// Maps the pane's existing connection flags — the footer invents no
    /// state of its own.
    public static func linkState(isConnected: Bool,
                                 awaitingDeviceReturn: Bool) -> LinkState {
        if isConnected { return .connected }
        return awaitingDeviceReturn ? .reconnecting : .disconnected
    }

    // MARK: - Counters + throttle

    /// Lifetime byte counters for the pane. They deliberately survive
    /// reconnects: the model belongs to the PANE, not to any one
    /// SerialConnection, and nothing here resets them.
    public private(set) var rxBytes: Int = 0
    public private(set) var txBytes: Int = 0

    /// Minimum seconds between UI repaints (0.25 = the ≤4 Hz cap).
    public let minInterval: TimeInterval

    private var lastEmit: TimeInterval = -.infinity
    private var pendingRepaint = false

    public init(minInterval: TimeInterval = 0.25) {
        self.minInterval = minInterval
    }

    /// True when a throttled repaint is owed (a trailing-edge flush must be
    /// scheduled so the last bytes of a burst are never left unpainted).
    public var hasPendingRepaint: Bool { pendingRepaint }

    /// Records traffic deltas. Returns true when the UI should repaint NOW
    /// (at least `minInterval` since the last repaint); false marks a
    /// pending repaint for `flushPendingRepaint`. `now` is any monotonic
    /// clock (injected — the TabActivity pattern).
    public mutating func recordTraffic(rx: Int, tx: Int, now: TimeInterval) -> Bool {
        rxBytes += max(0, rx)
        txBytes += max(0, tx)
        if now - lastEmit >= minInterval {
            lastEmit = now
            pendingRepaint = false
            return true
        }
        pendingRepaint = true
        return false
    }

    /// Trailing-edge flush, called from a one-shot timer armed when
    /// recordTraffic returned false: repaint exactly once for whatever
    /// accumulated during the throttle window. Rate stays ≤4 Hz because
    /// only one flush is ever armed per window.
    public mutating func flushPendingRepaint(now: TimeInterval) -> Bool {
        guard pendingRepaint else { return false }
        pendingRepaint = false
        lastEmit = now
        return true
    }

    public var rxDisplay: String { Self.formatBytes(rxBytes) }
    public var txDisplay: String { Self.formatBytes(txBytes) }

    /// Human units, tuned for a 22 pt strip: "0 B", "999 B", "1.2 KB",
    /// "348 KB", "12.7 MB". One decimal below 100 of a unit, none above
    /// (three significant-ish digits, stable width). 1024-based.
    public static func formatBytes(_ n: Int) -> String {
        let n = max(0, n)
        if n < 1024 { return "\(n) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(n)
        var unit = 0
        value /= 1024
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if value >= 100 {
            return "\(Int(value.rounded())) \(units[unit])"
        }
        return String(format: "%.1f %@", value, units[unit])
    }

    // MARK: - Settings summary ("115200-8N1 · RTS/CTS", baud clickable)

    /// The clickable half: just the rate.
    public static func baudText(_ settings: SerialSettings) -> String {
        "\(settings.baud)"
    }

    /// The static half after the baud control: "-8N1" plus the flow suffix
    /// when flow control is on — together they read "115200-8N1 · RTS/CTS".
    public static func frameText(_ settings: SerialSettings) -> String {
        let frame = "-\(settings.dataBits)\(settings.parity.rawValue)\(settings.stopBits)"
        guard let flow = flowLabel(settings.flow) else { return frame }
        return "\(frame) · \(flow)"
    }

    /// Human flow-control label; nil for none (no suffix — "115200-8N1").
    public static func flowLabel(_ flow: SerialSettings.FlowControl) -> String? {
        switch flow {
        case .none: return nil
        case .rtscts: return "RTS/CTS"
        case .xonxoff: return "XON/XOFF"
        }
    }
}
