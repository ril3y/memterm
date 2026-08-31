import Foundation

// Hex lens over the serial stream (feature/serial stage 1). Pure functions:
// the classic offset + hex + ASCII-gutter dump, incrementally streamable so
// the UI can render live RX without reformatting history, and a forgiving
// hex-input parser for the TX box ("DE AD BE EF", "0xde,0xad", "deadbeef").

/// Incremental hex-dump formatter. Feed bytes as they arrive; complete rows
/// come back from `append`, the trailing partial row from `flush()`. Output
/// matches the one-shot `SerialHex.dump` byte-for-byte.
public struct HexDumpFormatter {

    public let bytesPerRow: Int
    private var offset: Int = 0
    private var pending: [UInt8] = []

    public init(bytesPerRow: Int = 16) {
        self.bytesPerRow = max(1, bytesPerRow)
    }

    /// Appends bytes; returns zero or more COMPLETE rows (newline-terminated).
    public mutating func append<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        pending.append(contentsOf: bytes)
        var out = ""
        while pending.count >= bytesPerRow {
            let row = Array(pending.prefix(bytesPerRow))
            pending.removeFirst(bytesPerRow)
            out += Self.row(row, offset: offset, bytesPerRow: bytesPerRow) + "\n"
            offset += bytesPerRow
        }
        return out
    }

    /// Emits the trailing partial row (if any) and resets it.
    public mutating func flush() -> String {
        guard !pending.isEmpty else { return "" }
        let out = Self.row(pending, offset: offset, bytesPerRow: bytesPerRow) + "\n"
        offset += pending.count
        pending.removeAll()
        return out
    }

    /// One classic row: 8-digit offset, hex bytes (extra gap after 8), then
    /// the printable-ASCII gutter with '.' for everything else.
    static func row(_ bytes: [UInt8], offset: Int, bytesPerRow: Int) -> String {
        var hex = ""
        for i in 0..<bytesPerRow {
            if i > 0 { hex += i % 8 == 0 ? "  " : " " }
            hex += i < bytes.count ? String(format: "%02x", bytes[i]) : "  "
        }
        let ascii = bytes.map { b -> String in
            (0x20...0x7E).contains(b) ? String(UnicodeScalar(b)) : "."
        }.joined()
        return String(format: "%08x  ", offset) + hex + "  |" + ascii + "|"
    }
}

public enum SerialHex {

    /// One-shot dump of `data` — equivalent to streaming it through a
    /// `HexDumpFormatter` and flushing.
    public static func dump(_ data: Data, bytesPerRow: Int = 16) -> String {
        var f = HexDumpFormatter(bytesPerRow: bytesPerRow)
        return f.append(data) + f.flush()
    }

    /// Forgiving hex input for the TX path. Accepts "DE AD BE EF",
    /// "0xde,0xad", "de:ad:be:ef", contiguous "deadbeef", mixed case, and
    /// blank input (empty result). Returns nil for anything that is not
    /// unambiguously whole bytes (odd digit counts, non-hex characters).
    public static func parseInput(_ s: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        let separators = CharacterSet(charactersIn: " \t\r\n,:;")
        for tokenSub in s.components(separatedBy: separators) {
            var token = tokenSub
            if token.isEmpty { continue }
            if token.lowercased().hasPrefix("0x") { token.removeFirst(2) }
            if token.isEmpty { return nil }              // bare "0x"
            guard token.count % 2 == 0 else { return nil }
            var idx = token.startIndex
            while idx < token.endIndex {
                let next = token.index(idx, offsetBy: 2)
                guard let b = UInt8(token[idx..<next], radix: 16) else { return nil }
                bytes.append(b)
                idx = next
            }
        }
        return bytes
    }
}
