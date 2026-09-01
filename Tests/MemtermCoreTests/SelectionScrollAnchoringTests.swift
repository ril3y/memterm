import XCTest
import SwiftTerm

// SCROLL UX stage — headless Terminal-layer truth for "selection survives
// scroll" (founder ask 1). These certify that SwiftTerm's SelectionService
// keeps its coordinates anchored to buffer CONTENT while output feeds:
//   - absolute rows are stable while the scrollback grows (no trim), and
//   - rows shift in lockstep with CircularList recycling once the buffer is
//     full, so the selected TEXT never changes,
//   - a selection whose content is trimmed away is dropped honestly.
//
// The founder-visible bug lived one layer up: MacTerminalView.linefeed and
// AppleTerminalView.feedPrepare clear the selection on every output chunk
// whenever `allowMouseReporting` is true (the default) — even with no app
// tracking the mouse. PaneView now derives that flag through
// MouseReportingPolicy (ScrollUXTests) so these Terminal-layer guarantees
// reach the screen; the probe leg `selection-survives-stream` certifies the
// full path in a live pane.

private final class NullTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

final class SelectionScrollAnchoringTests: XCTestCase {

    private var delegate: NullTerminalDelegate!  // Terminal keeps tdel weakly

    private func makeTerminal(rows: Int = 10, cols: Int = 40,
                              scrollback: Int) -> (Terminal, SelectionService) {
        delegate = NullTerminalDelegate()
        let terminal = Terminal(delegate: delegate,
                                options: TerminalOptions(cols: cols, rows: rows,
                                                         scrollback: scrollback))
        let selection = SelectionService(terminal: terminal)
        return (terminal, selection)
    }

    private func feedLines(_ terminal: Terminal, _ range: ClosedRange<Int>,
                           prefix: String = "line") {
        for i in range {
            terminal.feed(text: "\(prefix)-\(i)\r\n")
        }
    }

    /// Buffer-absolute row (a Position row) whose full trimmed text equals
    /// `exact`, via the same scroll-invariant walk PaneView.scrollbackText
    /// uses.
    private func absoluteRow(of exact: String, in terminal: Terminal) -> Int? {
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            if line.translateToString(trimRight: true) == exact {
                return row - terminal.buffer.totalLinesTrimmed
            }
            row += 1
        }
        return nil
    }

    func testSelectionAnchorsWhileScrollbackGrows() throws {
        let (terminal, selection) = makeTerminal(scrollback: 500)
        terminal.feed(text: "SELMARK alpha\r\n")
        feedLines(terminal, 1...8)
        let row = try XCTUnwrap(absoluteRow(of: "SELMARK alpha", in: terminal))

        selection.setSoftStart(bufferPosition: Position(col: 0, row: row))
        selection.startSelection()
        selection.dragExtend(bufferPosition: Position(col: 7, row: row))
        let before = selection.getSelectedText()
        XCTAssertTrue(before.contains("SELMARK"), "selected \(before.debugDescription)")

        // Stream well past the viewport — no trimming yet (scrollback 500).
        feedLines(terminal, 9...80)

        XCTAssertTrue(selection.active)
        XCTAssertEqual(selection.getSelectedText(), before,
                       "selection must stay glued to the content it was made on")
        XCTAssertEqual(selection.start.row, row,
                       "absolute rows are stable while nothing is trimmed")
        XCTAssertEqual(terminal.buffer.totalLinesTrimmed, 0)
    }

    func testSelectionShiftsWithScrollbackRecycling() throws {
        // rows 10 + scrollback 5 → the buffer fills quickly and recycles.
        let (terminal, selection) = makeTerminal(scrollback: 5)
        feedLines(terminal, 1...20)  // buffer full, trimming underway
        terminal.feed(text: "SELMARK beta\r\n")
        feedLines(terminal, 21...24)
        let row = try XCTUnwrap(absoluteRow(of: "SELMARK beta", in: terminal))

        selection.setSoftStart(bufferPosition: Position(col: 0, row: row))
        selection.startSelection()
        selection.dragExtend(bufferPosition: Position(col: 7, row: row))
        let before = selection.getSelectedText()
        XCTAssertTrue(before.contains("SELMARK"), "selected \(before.debugDescription)")

        let trimmedBefore = terminal.buffer.totalLinesTrimmed
        XCTAssertGreaterThan(trimmedBefore, 0, "test needs a full, recycling buffer")
        feedLines(terminal, 25...27)
        let shifted = terminal.buffer.totalLinesTrimmed - trimmedBefore
        XCTAssertEqual(shifted, 3)

        XCTAssertTrue(selection.active)
        XCTAssertEqual(selection.start.row, row - shifted,
                       "selection rows must shift in lockstep with recycled lines")
        XCTAssertEqual(selection.getSelectedText(), before,
                       "the selected TEXT must not change when the buffer recycles")
    }

    func testMidDragExtensionStaysGluedAcrossRecycling() throws {
        let (terminal, selection) = makeTerminal(scrollback: 5)
        feedLines(terminal, 1...20)
        terminal.feed(text: "DRAGMARK start\r\n")
        feedLines(terminal, 21...23)
        let row = try XCTUnwrap(absoluteRow(of: "DRAGMARK start", in: terminal))

        // A drag in flight: pressed on the marker, extended two rows down.
        selection.setSoftStart(bufferPosition: Position(col: 0, row: row))
        selection.startSelection()
        selection.dragExtend(bufferPosition: Position(col: 7, row: row + 2))
        let before = selection.getSelectedText()

        // Output streams while the button is still down.
        terminal.feed(text: "DRAGMARK target\r\n")
        feedLines(terminal, 24...26)
        XCTAssertTrue(selection.active)
        XCTAssertEqual(selection.getSelectedText(), before,
                       "an in-flight drag must not lose its content anchor")

        // The drag continues — to the CURRENT position of later content
        // (exactly what mouseDragged passes: the hit under the pointer now).
        let target = try XCTUnwrap(absoluteRow(of: "DRAGMARK target", in: terminal))
        selection.dragExtend(bufferPosition: Position(col: 15, row: target))
        let extended = selection.getSelectedText()
        XCTAssertTrue(extended.contains("DRAGMARK start"),
                      "the drag's starting content stays in the selection")
        XCTAssertTrue(extended.contains("DRAGMARK target"),
                      "the extension covers the content dragged over")
    }

    func testSelectionDropsHonestlyWhenContentIsTrimmedAway() throws {
        let (terminal, selection) = makeTerminal(scrollback: 5)
        feedLines(terminal, 1...20)
        // Select the OLDEST surviving line — the next trims destroy it.
        selection.setSoftStart(bufferPosition: Position(col: 0, row: 0))
        selection.startSelection()
        selection.dragExtend(bufferPosition: Position(col: 5, row: 0))
        XCTAssertTrue(selection.active)

        feedLines(terminal, 21...40)
        XCTAssertFalse(selection.active,
                       "content gone from the buffer → the selection is dropped, not remapped")
    }
}
