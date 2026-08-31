import Foundation

// FR-16 (v0, plain text): pure assembly of engine buffer rows into the
// serialized scrollback form — wrapped rows re-joined, trailing blank grid
// rows trimmed, capped to maxLines. The engine-facing extraction stays in
// PaneView; this is the part worth testing without a terminal.

public enum ScrollbackText {

    public struct Row {
        public var text: String
        /// True when the engine soft-wrapped this row from the previous one.
        public var isWrapped: Bool

        public init(text: String, isWrapped: Bool) {
            self.text = text
            self.isWrapped = isWrapped
        }
    }

    public static func assemble(rows: [Row], maxLines: Int) -> String {
        var lines: [String] = []
        for row in rows {
            if row.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += row.text
            } else {
                lines.append(row.text)
            }
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        return lines.joined(separator: "\n")
    }

    /// LF-joined serialized scrollback → CRLF text safe to feed() into a
    /// terminal view as ghost history (display only — never written to a pty).
    public static func ghostFeedText(_ serialized: String) -> String {
        serialized.replacingOccurrences(of: "\n", with: "\r\n")
    }
}
