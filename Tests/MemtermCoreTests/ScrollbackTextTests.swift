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

    // MARK: fileURL containment (pane ids come from user-inspectable files)

    func testFileURLNeverEscapesScrollbackDir() {
        let dir = URL(fileURLWithPath: "/data/scrollback", isDirectory: true)
        for hostile in ["../../../etc/passwd",
                        "..",
                        "/etc/passwd",
                        "a/b",
                        "..\\..\\x",
                        ".hidden",
                        ""] {
            let url = ScrollbackText.fileURL(dir: dir, paneId: hostile).standardizedFileURL
            XCTAssertTrue(url.path.hasPrefix("/data/scrollback/"),
                          "pane id \(hostile) escaped to \(url.path)")
            XCTAssertFalse(url.path.contains(".."), "traversal survived for \(hostile)")
            XCTAssertEqual(url.pathComponents.count, dir.pathComponents.count + 1,
                           "pane id \(hostile) added extra path components")
        }
    }

    func testFileURLKeepsUUIDPaneIdsVerbatim() {
        let dir = URL(fileURLWithPath: "/data/scrollback", isDirectory: true)
        let uuid = "6C2B41D8-90BE-44F6-AF3E-DDA4EFFA24BB"
        XCTAssertEqual(ScrollbackText.fileURL(dir: dir, paneId: uuid).lastPathComponent,
                       "\(uuid).txt")
        XCTAssertEqual(ScrollbackText.safePaneId(uuid), uuid)
    }

    // MARK: Restore-divider collapse (council #9: no more marker piles)

    private func divider(_ stamp: String, earlier: Int = 0) -> String {
        ScrollbackText.restoredDividerLine(stamp: stamp, earlierSessions: earlier)
    }

    func testDividerLineRoundTripsThroughParse() {
        let plain = divider("Sep 2 10:15 AM")
        XCTAssertEqual(plain, "── restored — Sep 2 10:15 AM ──")
        XCTAssertEqual(ScrollbackText.parseRestoredDivider(plain)?.stamp, "Sep 2 10:15 AM")
        XCTAssertEqual(ScrollbackText.parseRestoredDivider(plain)?.earlierSessions, 0)

        let collapsed = divider("Sep 2 10:15 AM", earlier: 3)
        XCTAssertEqual(collapsed, "── restored — Sep 2 10:15 AM · 3 earlier sessions ──")
        let parsed = ScrollbackText.parseRestoredDivider(collapsed)
        XCTAssertEqual(parsed?.stamp, "Sep 2 10:15 AM")
        XCTAssertEqual(parsed?.earlierSessions, 3)

        let one = divider("Sep 2 10:15 AM", earlier: 1)
        XCTAssertEqual(one, "── restored — Sep 2 10:15 AM · 1 earlier session ──")
        XCTAssertEqual(ScrollbackText.parseRestoredDivider(one)?.earlierSessions, 1)
    }

    func testParseRejectsNonDividerLines() {
        for line in ["", "hello", "── reconnected — Sep 2 ──", "restored — x ──",
                     "── restored —  ──", "memterm: was running claude"] {
            XCTAssertNil(ScrollbackText.parseRestoredDivider(line), "parsed: \(line)")
        }
    }

    func testCollapseLeavesGhostsWithoutPilesUntouched() {
        let ghost = "content\n\(divider("Sep 1 9:00 AM"))\nmore content"
        XCTAssertEqual(ScrollbackText.collapseRestoredDividers(ghost), ghost)
        XCTAssertEqual(ScrollbackText.collapseRestoredDividers("plain\ntext"), "plain\ntext")
    }

    func testCollapseStackedDividers() {
        let ghost = [
            "session one output",
            divider("Sep 1 9:00 AM"),
            divider("Sep 1 9:05 AM"),
            divider("Sep 2 8:00 AM"),
            "typed after the pile",
        ].joined(separator: "\n")
        XCTAssertEqual(ScrollbackText.collapseRestoredDividers(ghost), [
            "session one output",
            divider("Sep 2 8:00 AM", earlier: 2),
            "typed after the pile",
        ].joined(separator: "\n"))
    }

    func testCollapseDropsOnlyMemtermNoiseBetweenGenerations() {
        let ghost = [
            divider("Sep 1 9:00 AM"),
            "memterm: was running claude — press ⌘R to type: claude --resume",
            "",
            divider("Sep 1 9:05 AM"),
            "$ real prompt output",   // content breaks the run — preserved
            divider("Sep 2 8:00 AM"),
        ].joined(separator: "\n")
        XCTAssertEqual(ScrollbackText.collapseRestoredDividers(ghost), [
            divider("Sep 1 9:05 AM", earlier: 1),
            "$ real prompt output",
            divider("Sep 2 8:00 AM"),
        ].joined(separator: "\n"))
    }

    func testCollapseKeepsNoiseThatIsFollowedByContent() {
        let ghost = [
            divider("Sep 1 9:00 AM"),
            divider("Sep 1 9:05 AM"),
            "memterm: was running claude — press ⌘R",
            "$ ls",
        ].joined(separator: "\n")
        XCTAssertEqual(ScrollbackText.collapseRestoredDividers(ghost), [
            divider("Sep 1 9:05 AM", earlier: 1),
            "memterm: was running claude — press ⌘R",
            "$ ls",
        ].joined(separator: "\n"))
    }

    func testCollapseAccumulatesAlreadyCollapsedGenerations() {
        // The pile never regrows: a collapsed line merging with newer
        // dividers carries its count forward.
        let ghost = [
            divider("Sep 1 9:05 AM", earlier: 3),
            divider("Sep 2 8:00 AM"),
            divider("Sep 2 8:10 AM"),
        ].joined(separator: "\n")
        XCTAssertEqual(ScrollbackText.collapseRestoredDividers(ghost),
                       divider("Sep 2 8:10 AM", earlier: 5))
    }

    func testCollapseIsIdempotent() {
        let ghost = [
            "output",
            divider("Sep 1 9:00 AM"),
            divider("Sep 2 8:00 AM"),
            "tail",
        ].joined(separator: "\n")
        let once = ScrollbackText.collapseRestoredDividers(ghost)
        XCTAssertEqual(ScrollbackText.collapseRestoredDividers(once), once)
    }

    func testCollapseTrailingPileAtGhostEnd() {
        let ghost = [
            "last real output",
            divider("Sep 1 9:00 AM"),
            "",
            divider("Sep 2 8:00 AM"),
        ].joined(separator: "\n")
        XCTAssertEqual(ScrollbackText.collapseRestoredDividers(ghost), [
            "last real output",
            divider("Sep 2 8:00 AM", earlier: 1),
        ].joined(separator: "\n"))
    }
}

// Founder bug 2026-09-09: ghost history read "Theexitcodecamefromthelastls" —
// never-written cells (TUI renderers skip space runs with cursor-forward)
// serialized as NUL and vanished on replay. Pure half of the gate; the
// capture half (wide-glyph padding excluded) is CaptureCellsTests.
final class ScrollbackNulCellTests: XCTestCase {
    func testNeverWrittenCellsSerializeAsSpaces() {
        let text = ScrollbackText.assemble(rows: [
            ScrollbackText.Row(text: "The\0exit\0code", isWrapped: false),
        ], maxLines: 10)
        XCTAssertEqual(text, "The exit code")
        XCTAssertFalse(text.contains("\0"))
    }

    /// Captures written before the fix carry NULs on disk — the ghost feed
    /// heals them so existing history reads correctly too.
    func testGhostFeedHealsLegacyNuls() {
        XCTAssertEqual(ScrollbackText.ghostFeedText("a\0b\nc"), "a b\r\nc")
    }

    func testNormalizeIsIdentityWithoutNuls() {
        XCTAssertEqual(ScrollbackText.normalizeCells("plain text"), "plain text")
    }
}
