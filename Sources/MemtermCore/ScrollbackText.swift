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

    /// Founder bug 2026-09-09 (ghost text "Theexitcodecamefromthelastls"):
    /// a terminal cell that was never written — TUI renderers (Claude Code's
    /// included) skip runs of spaces with cursor-forward moves instead of
    /// emitting spaces — is code 0 in the engine buffer, and the engine's
    /// line-to-string conversion emits it as a literal NUL. Fed back as
    /// ghost history, the parser drops NUL, so every skipped gap vanished
    /// and words glued together. On the grid a never-written cell IS a
    /// blank, so the serialized form says so.
    public static func normalizeCells(_ text: String) -> String {
        text.contains("\0") ? text.replacingOccurrences(of: "\0", with: " ") : text
    }

    public static func assemble(rows: [Row], maxLines: Int) -> String {
        var lines: [String] = []
        for row in rows {
            let text = normalizeCells(row.text)
            if row.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        return lines.joined(separator: "\n")
    }

    /// Pane ids are UUIDs at creation, but they round-trip through the DB and
    /// split-tree JSON — both user-inspectable files (Persona B reads our disk
    /// format). An id used as a path component must never escape the
    /// scrollback dir: anything outside [A-Za-z0-9-] is replaced, so "../" and
    /// absolute-path shapes cannot reach removeItem/write as traversal.
    public static func safePaneId(_ paneId: String) -> String {
        let cleaned = String(paneId.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-"
                ? Character(scalar) : "_"
        })
        return cleaned.isEmpty ? "_invalid" : cleaned
    }

    /// On-disk location of one pane's serialized scrollback. Single source of
    /// the naming scheme: the capture engine writes here and workspace-forget
    /// (FR-57) deletes here.
    public static func fileURL(dir: URL, paneId: String) -> URL {
        dir.appendingPathComponent("\(safePaneId(paneId)).txt")
    }

    /// LF-joined serialized scrollback → CRLF text safe to feed() into a
    /// terminal view as ghost history (display only — never written to a pty).
    /// Captures written before the NUL fix (2026-09-09) still carry NULs on
    /// disk; healing them here keeps every existing ghost readable.
    public static func ghostFeedText(_ serialized: String) -> String {
        normalizeCells(serialized).replacingOccurrences(of: "\n", with: "\r\n")
    }

    // MARK: - Restore dividers (council #9: collapse stacked generations)

    private static let dividerPrefix = "── restored — "
    private static let dividerSuffix = " ──"

    /// The single source of the restore-divider line shape. The restore path
    /// feeds this (in color); the capture round-trips it as plain text, and
    /// `collapseRestoredDividers` parses exactly this shape back.
    public static func restoredDividerLine(stamp: String, earlierSessions: Int = 0) -> String {
        guard earlierSessions > 0 else { return dividerPrefix + stamp + dividerSuffix }
        let unit = earlierSessions == 1 ? "earlier session" : "earlier sessions"
        return "\(dividerPrefix)\(stamp) · \(earlierSessions) \(unit)\(dividerSuffix)"
    }

    /// Parses a (plain-text) restore divider line — either the plain form
    /// `── restored — <stamp> ──` or the collapsed form
    /// `── restored — <stamp> · N earlier sessions ──`. Nil for anything else.
    public static func parseRestoredDivider(_ line: String) -> (stamp: String, earlierSessions: Int)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(dividerPrefix), trimmed.hasSuffix(dividerSuffix),
              trimmed.count > dividerPrefix.count + dividerSuffix.count else { return nil }
        let inner = String(trimmed.dropFirst(dividerPrefix.count).dropLast(dividerSuffix.count))
        guard !inner.isEmpty else { return nil }
        // Collapsed form: "<stamp> · N earlier session(s)".
        if let sep = inner.range(of: " · ", options: .backwards) {
            let tail = String(inner[sep.upperBound...])
            let parts = tail.split(separator: " ")
            if parts.count == 3, let n = Int(parts[0]), n > 0, parts[1] == "earlier",
               parts[2] == "session" || parts[2] == "sessions" {
                let stamp = String(inner[..<sep.lowerBound])
                return stamp.isEmpty ? nil : (stamp, n)
            }
        }
        return (inner, 0)
    }

    /// A line the collapse may drop when it sits BETWEEN two restore dividers:
    /// blank lines and memterm's own restore chrome (`memterm: …` offer /
    /// notice lines from a dead generation). Never user output.
    private static func isRestoreNoise(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("memterm: ")
    }

    /// Council finding #9: after several relaunches a pane's ghost opens on a
    /// pile of `── restored — … ──` markers. This collapses every run of
    /// consecutive divider generations (dividers separated only by blank
    /// lines / memterm's own stale offer lines) into ONE line —
    /// `── restored — <latest> · N earlier sessions ──` — accumulating counts
    /// from already-collapsed lines so the pile never regrows. User content
    /// always breaks a run and is preserved verbatim: the ghost stays
    /// searchable. Single dividers (real sessions between them) are untouched.
    public static func collapseRestoredDividers(_ serialized: String) -> String {
        guard serialized.contains(dividerPrefix) else { return serialized }
        var out: [String] = []
        // The active run of divider generations, plus noise lines held in
        // limbo (dropped only if another divider extends the run; emitted
        // untouched when real content follows instead).
        var run: [(line: String, stamp: String, earlier: Int)] = []
        var limbo: [String] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count == 1 {
                out.append(run[0].line)
            } else {
                let earlier = run.reduce(0) { $0 + $1.earlier } + run.count - 1
                out.append(restoredDividerLine(stamp: run[run.count - 1].stamp,
                                               earlierSessions: earlier))
            }
            run = []
        }

        for line in serialized.components(separatedBy: "\n") {
            if let divider = parseRestoredDivider(line) {
                limbo = []  // noise between merged generations is dropped
                run.append((line, divider.stamp, divider.earlierSessions))
            } else if !run.isEmpty, isRestoreNoise(line) {
                limbo.append(line)
            } else {
                flushRun()
                out.append(contentsOf: limbo)
                limbo = []
                out.append(line)
            }
        }
        flushRun()
        out.append(contentsOf: limbo)
        return out.joined(separator: "\n")
    }
}
