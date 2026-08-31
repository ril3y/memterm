import Foundation

// Serial line configuration (feature/serial stage 1). Plain value type with a
// compact string form for the journal — "115200-8N1" / "9600-7E1-xonxoff" —
// that round-trips exactly (parse + format, unit-tested). Defaults follow the
// UX research consensus: 115200 8N1, flow control none (XON/XOFF ON by
// default silently eats 0x11/0x13 in binary streams).
public struct SerialSettings: Equatable, Codable {

    public enum Parity: String, Codable, CaseIterable {
        case none = "N"
        case even = "E"
        case odd = "O"
    }

    public enum FlowControl: String, Codable, CaseIterable {
        case none
        case rtscts
        case xonxoff
    }

    /// Common ladder shown in pickers; also what auto-baud cycles through.
    /// 74880 is the ESP8266 boot-ROM rate — non-standard but seen daily.
    public static let standardBauds: [Int] = [
        300, 1200, 2400, 4800, 9600, 19200, 38400, 57600,
        115200, 230400, 460800, 921600,
    ]

    public var baud: Int
    public var dataBits: Int      // 5...8
    public var parity: Parity
    public var stopBits: Int      // 1 or 2
    public var flow: FlowControl

    public init(baud: Int = 115200, dataBits: Int = 8, parity: Parity = .none,
                stopBits: Int = 1, flow: FlowControl = .none) {
        self.baud = baud
        self.dataBits = dataBits
        self.parity = parity
        self.stopBits = stopBits
        self.flow = flow
    }

    /// True when `baud` is in the classic Bxxx set a driver is guaranteed to
    /// take via plain tcsetattr; anything else goes through IOSSIOSPEED.
    public var isStandardBaud: Bool { Self.standardBauds.contains(baud) }

    /// Nearest standard rate — the termios rate set before an IOSSIOSPEED
    /// override (the documented reliable path for arbitrary rates).
    public var nearestStandardBaud: Int {
        Self.standardBauds.min { abs($0 - baud) < abs($1 - baud) } ?? 115200
    }

    // MARK: Compact string form ("115200-8N1", "115200-8N1-rtscts")

    public var compactString: String {
        let frame = "\(baud)-\(dataBits)\(parity.rawValue)\(stopBits)"
        return flow == .none ? frame : "\(frame)-\(flow.rawValue)"
    }

    /// Parses the compact form. Forgiving about case and an explicit "-none"
    /// flow suffix; strict about everything that would mis-configure a port.
    public static func parse(_ s: String) -> SerialSettings? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "-")
        guard parts.count == 2 || parts.count == 3 else { return nil }

        guard let baud = Int(parts[0]), baud > 0 else { return nil }

        let frame = parts[1].uppercased()
        guard frame.count == 3 else { return nil }
        let chars = Array(frame)
        guard let dataBits = chars[0].wholeNumberValue, (5...8).contains(dataBits),
              let parity = Parity(rawValue: String(chars[1])),
              let stopBits = chars[2].wholeNumberValue, (1...2).contains(stopBits)
        else { return nil }

        var flow = FlowControl.none
        if parts.count == 3 {
            guard let f = FlowControl(rawValue: parts[2].lowercased()) else { return nil }
            flow = f
        }
        return SerialSettings(baud: baud, dataBits: dataBits, parity: parity,
                              stopBits: stopBits, flow: flow)
    }
}

/// What the Enter key transmits from a serial pane. The terminal view emits a
/// bare CR (0x0D) for Return; devices disagree about what a "line" is, so the
/// TX ending is per-pane configurable (research: CRLF is the least-surprising
/// default for Arduino/ESP monitors). `.none` swallows Return entirely —
/// useful against binary protocols where a stray 0x0D corrupts a frame.
public enum SerialLineEnding: String, CaseIterable, Codable {
    case cr, lf, crlf, none

    /// Config/journal value list, in UI order.
    public static let configValues = ["cr", "lf", "crlf", "none"]

    /// Human labels, index-matched to `configValues`.
    public static let labels = ["CR", "LF", "CRLF", "None"]

    public var bytes: [UInt8] {
        switch self {
        case .cr: return [0x0D]
        case .lf: return [0x0A]
        case .crlf: return [0x0D, 0x0A]
        case .none: return []
        }
    }

    /// Maps every CR in the outgoing keystroke bytes to this ending. Only CR
    /// is rewritten — Ctrl-C and every other byte pass through untouched
    /// (serial panes have no signal semantics, bytes are bytes).
    public func transformOutgoing(_ data: [UInt8]) -> [UInt8] {
        if self == .cr { return data }
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 4)
        for b in data {
            if b == 0x0D {
                out.append(contentsOf: bytes)
            } else {
                out.append(b)
            }
        }
        return out
    }
}
