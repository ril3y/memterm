import Foundation

// FR-4 (⌘F search): the pure logic behind the per-pane find bar. The search
// itself runs in the terminal engine (it owns the buffer, including restored
// ghost scrollback, which was feed()'d into the same buffer); what the bar
// shows and how ⌘F seeds its field are plain functions worth testing headlessly.

public enum FindSupport {

    /// Label for the find bar's match counter. The engine caps its match scan
    /// at `limit`, so a saturated total renders as "1000+". `index` is 1-based;
    /// 0 means matches exist but none is current (e.g. the buffer scrolled on
    /// under live output since the last jump).
    public static func matchCountLabel(index: Int, total: Int, limit: Int = 1000) -> String {
        guard total > 0 else { return "no matches" }
        let totalText = total >= limit ? "\(limit)+" : "\(total)"
        guard index > 0 else { return totalText }
        return "\(index)/\(totalText)"
    }

    /// The term ⌘F seeds the find field with from the current selection.
    /// Only compact single-line selections make useful search terms; anything
    /// spanning lines (or absurdly long) returns nil and the field keeps its
    /// previous term.
    public static func prefillTerm(fromSelection selection: String?,
                                   maxLength: Int = 200) -> String? {
        guard let selection, !selection.isEmpty,
              // Scalar-level check: "\r\n" is a single Character, so a
              // grapheme-level contains("\n") would miss CRLF selections.
              selection.rangeOfCharacter(from: .newlines) == nil,
              selection.count <= maxLength else { return nil }
        return selection
    }
}
