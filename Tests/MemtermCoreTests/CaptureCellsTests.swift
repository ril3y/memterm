import XCTest
import SwiftTerm
@testable import MemtermCore

// Founder bug 2026-09-09 (ghost text lost its spaces): the capture half of
// the gate, against a headless SwiftTerm Terminal — the same engine truth
// PaneView.scrollbackText rides on. Mirrors that method's translate flags
// exactly so a drift there fails HERE, not in the founder's ghost.
private final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class CaptureCellsTests: XCTestCase {
    private var delegate: NullTerminalDelegate!

    private func capture(_ feed: String, cols: Int = 40) -> String {
        delegate = NullTerminalDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: cols, rows: 5, scrollback: 50))
        terminal.feed(text: feed)
        var rows: [ScrollbackText.Row] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            rows.append(ScrollbackText.Row(
                text: line.translateToString(trimRight: true,
                                             skipNullCellsFollowingWide: true),
                isWrapped: line.isWrapped))
            row += 1
        }
        return ScrollbackText.assemble(rows: rows, maxLines: 50)
    }

    /// THE bug: a renderer that skips spaces with CUF (cursor forward) leaves
    /// never-written cells; the capture must serialize them as spaces.
    func testCursorForwardGapsCaptureAsSpaces() {
        let text = capture("The\u{1b}[1Cexit\u{1b}[3Ccode\r\n")
        XCTAssertEqual(text, "The exit   code")
        XCTAssertFalse(text.contains("\0"))
    }

    /// Absolute cursor positioning (CHA) is the other common skip.
    func testCursorPositionGapsCaptureAsSpaces() {
        let text = capture("ab\u{1b}[6Gcd\r\n")
        XCTAssertEqual(text, "ab   cd")
    }

    /// A wide glyph's padding cell is code 0 as well — it must NOT become a
    /// phantom space after every CJK/emoji character.
    func testWideGlyphPaddingIsNotASpace() {
        let text = capture("日本\u{1b}[2Cx\r\n")
        XCTAssertEqual(text, "日本  x")
    }

    func testPlainTextRoundTrips() {
        XCTAssertEqual(capture("hello world\r\n"), "hello world")
    }
}
