import XCTest
@testable import MemtermCore

final class ScrollbackTextTests: XCTestCase {

    private func row(_ text: String, wrapped: Bool = false) -> ScrollbackText.Row {
        ScrollbackText.Row(text: text, isWrapped: wrapped)
    }

    func testWrappedRowsAreRejoined() {
        let text = ScrollbackText.assemble(rows: [
            row("$ make very-long-comman"),
            row("d-that-wrapped", wrapped: true),
            row("done"),
        ], maxLines: 100)
        XCTAssertEqual(text, "$ make very-long-command-that-wrapped\ndone")
    }

    func testTrailingBlankRowsAreTrimmedButInteriorBlanksKept() {
        let text = ScrollbackText.assemble(rows: [
            row("first"),
            row(""),
            row("after-gap"),
            row(""),
            row(""),
        ], maxLines: 100)
        XCTAssertEqual(text, "first\n\nafter-gap")
    }

    func testMaxLinesCapKeepsNewestLines() {
        let rows = (1...10).map { row("line-\($0)") }
        let text = ScrollbackText.assemble(rows: rows, maxLines: 3)
        XCTAssertEqual(text, "line-8\nline-9\nline-10")
    }

    func testCapAppliesAfterRejoiningWrappedRows() {
        let text = ScrollbackText.assemble(rows: [
            row("aaa"), row("bbb", wrapped: true),  // one logical line
            row("ccc"),
            row("ddd"),
        ], maxLines: 2)
        XCTAssertEqual(text, "ccc\nddd")
    }

    func testEmptyInput() {
        XCTAssertEqual(ScrollbackText.assemble(rows: [], maxLines: 10), "")
        XCTAssertEqual(ScrollbackText.assemble(rows: [row(""), row("")], maxLines: 10), "")
    }

    func testGhostFeedTextConvertsLFtoCRLF() {
        XCTAssertEqual(ScrollbackText.ghostFeedText("a\nb\nc"), "a\r\nb\r\nc")
        XCTAssertEqual(ScrollbackText.ghostFeedText("plain"), "plain")
    }
}
