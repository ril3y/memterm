import XCTest
@testable import MemtermCore

/// Founder ask 2026-10-29: right-click a file path or URL in the terminal to
/// copy it — e.g. on the path in
/// "File: /private/tmp/claude-501/…/scratchpad/synthetos.com.zone".
/// TerminalLinkDetect finds the token under the click; these tests pin what
/// counts as one and where it ends.
final class TerminalLinkDetectTests: XCTestCase {

    /// Detects at the position of `marker`'s first character inside `line`.
    private func detect(_ line: String, at marker: String) -> DetectedLink? {
        let chars = Array(line)
        guard let r = line.range(of: marker) else {
            XCTFail("marker \(marker) not in line"); return nil
        }
        return TerminalLinkDetect.link(in: chars, at: line.distance(from: line.startIndex, to: r.lowerBound))
    }

    // MARK: - Paths

    func testTheFoundersExample() {
        let path = "/private/tmp/claude-501/-Volumes-External-projects-synthetos/63529101-5513-4d34-8ff8-3362ab5e289d/scratchpad/synthetos.com.zone"
        let line = "File: \(path)"
        XCTAssertEqual(detect(line, at: "synthetos.com"), DetectedLink(kind: .path, text: path))
        XCTAssertEqual(detect(line, at: "/private"), DetectedLink(kind: .path, text: path))
        // The label itself is not a path.
        XCTAssertNil(detect(line, at: "File"))
    }

    func testHomeAndRelativePaths() {
        XCTAssertEqual(detect("cat ~/notes/todo.md", at: "todo")?.text, "~/notes/todo.md")
        XCTAssertEqual(detect("open ./build/out.log now", at: "out")?.text, "./build/out.log")
        XCTAssertEqual(detect("see ../x/y", at: "y")?.text, "../x/y")
        XCTAssertEqual(detect("M Sources/memterm/App.swift", at: "App")?.text, "Sources/memterm/App.swift")
    }

    func testLineAndColumnSuffixesAreSplitOff() {
        let link = detect("Sources/memterm/App.swift:233:12: error: nope", at: "App")
        XCTAssertEqual(link, DetectedLink(kind: .path, text: "Sources/memterm/App.swift", lineSuffix: ":233:12"))
        XCTAssertEqual(detect("/a/b.swift:7", at: "b")?.lineSuffix, ":7")
    }

    func testSurroundingQuotesBracketsAndPunctuationAreTrimmed() {
        XCTAssertEqual(detect("wrote '/tmp/a b.txt'", at: "/tmp")?.text, "/tmp/a")  // spaces end a token
        XCTAssertEqual(detect("(see /etc/hosts).", at: "hosts")?.text, "/etc/hosts")
        XCTAssertEqual(detect("\"/usr/local/bin\",", at: "local")?.text, "/usr/local/bin")
        XCTAssertEqual(detect("<~/x/y>", at: "x")?.text, "~/x/y")
        XCTAssertEqual(detect("saved to /var/log/system.log.", at: "system")?.text, "/var/log/system.log")
    }

    func testAKeyEqualsPrefixIsDropped() {
        XCTAssertEqual(detect("--config=/etc/memterm.toml", at: "memterm")?.text, "/etc/memterm.toml")
        XCTAssertEqual(detect("path=~/a/b", at: "a/b")?.text, "~/a/b")
    }

    func testWordsWithoutASlashAreNotPaths() {
        XCTAssertNil(detect("hello world", at: "world"))
        XCTAssertNil(detect("version 1.2.3", at: "1.2"))
        XCTAssertNil(detect("a / b", at: "/"))      // a lone slash
        XCTAssertNil(detect("ratio 3/4", at: "3/4"))  // a fraction
    }

    // MARK: - URLs

    func testURLs() {
        XCTAssertEqual(detect("visit https://example.com/a?b=c#d now", at: "example"),
                       DetectedLink(kind: .url, text: "https://example.com/a?b=c#d"))
        XCTAssertEqual(detect("ssh://git@github.com/x.git", at: "github")?.kind, .url)
        XCTAssertEqual(detect("mail mailto:a@b.co", at: "mailto")?.text, "mailto:a@b.co")
        XCTAssertEqual(detect("file:///tmp/x", at: "tmp")?.kind, .url)
    }

    func testURLTrailingPunctuationAndBalancedParens() {
        XCTAssertEqual(detect("(https://example.com/x).", at: "example")?.text, "https://example.com/x")
        XCTAssertEqual(detect("https://en.wikipedia.org/wiki/Foo_(bar)", at: "wiki")?.text,
                       "https://en.wikipedia.org/wiki/Foo_(bar)")
        XCTAssertEqual(detect("go to https://a.io/b, then", at: "a.io")?.text, "https://a.io/b")
    }

    func testAURLIsNeverSplitIntoAPathLineSuffix() {
        XCTAssertEqual(detect("http://localhost:8080/x", at: "localhost"),
                       DetectedLink(kind: .url, text: "http://localhost:8080/x"))
    }

    func testABareWwwHostIsAURL() {
        XCTAssertEqual(detect("see www.example.com/docs", at: "example"),
                       DetectedLink(kind: .url, text: "www.example.com/docs"))
    }

    // MARK: - Edges

    func testClickingWhitespaceFindsNothing() {
        XCTAssertNil(detect("/a/b   /c/d", at: "  "))
    }

    func testOutOfRangeIndexFindsNothing() {
        XCTAssertNil(TerminalLinkDetect.link(in: Array("/a/b"), at: 10))
        XCTAssertNil(TerminalLinkDetect.link(in: [], at: 0))
    }

    // MARK: - Joining wrapped rows

    private func cells(_ s: String) -> [TerminalCellText] {
        s.map { TerminalCellText(character: $0, width: 1) }
    }

    func testWrappedRowsJoinIntoOneLine() {
        // A path wrapped across three rows of a 10-column pane; the click is
        // on the middle row.
        let rows = [cells("File: /pri"), cells("vate/tmp/a"), cells(".zone     ")]
        let joined = TerminalLinkDetect.logicalLine(rows: rows, wrapped: [false, true, true],
                                                    clickRow: 1, clickCol: 3)
        XCTAssertEqual(String(joined.text), "File: /private/tmp/a.zone     ")
        XCTAssertEqual(joined.index, 13)  // the "e" of "private"
        XCTAssertEqual(TerminalLinkDetect.link(in: joined.text, at: joined.index)?.text,
                       "/private/tmp/a.zone")
    }

    func testOnlyTheClickedRowsWrapRunIsJoined() {
        let rows = [cells("/one/a    "), cells("/two/b    "), cells("/thr"), cells("ee/c")]
        let joined = TerminalLinkDetect.logicalLine(rows: rows, wrapped: [false, false, false, true],
                                                    clickRow: 3, clickCol: 1)
        XCTAssertEqual(String(joined.text), "/three/c")
        XCTAssertEqual(joined.index, 5)
    }

    func testWideCharacterFollowerCellsMapToTheirCharacter() {
        // "日" occupies cols 0-1 (the follower cell has width 0).
        let row = [TerminalCellText(character: "日", width: 2),
                   TerminalCellText(character: " ", width: 0),
                   TerminalCellText(character: "/", width: 1),
                   TerminalCellText(character: "a", width: 1)]
        let onFollower = TerminalLinkDetect.logicalLine(rows: [row], wrapped: [false],
                                                        clickRow: 0, clickCol: 1)
        XCTAssertEqual(String(onFollower.text), "日/a")
        XCTAssertEqual(onFollower.index, 0)
        let onSlash = TerminalLinkDetect.logicalLine(rows: [row], wrapped: [false],
                                                     clickRow: 0, clickCol: 2)
        XCTAssertEqual(onSlash.index, 1)
    }

    func testNulCellsReadAsSpaces() {
        let row = [TerminalCellText(character: "\u{0}", width: 1)] + cells("/a/b")
        let joined = TerminalLinkDetect.logicalLine(rows: [row], wrapped: [false],
                                                    clickRow: 0, clickCol: 2)
        XCTAssertEqual(String(joined.text), " /a/b")
    }

    // MARK: - Point to cell

    func testPointToCell() {
        // 8x16 cells, 10 rows tall view (160pt); AppKit y grows upward.
        let hit = TerminalLinkDetect.cell(atX: 17, y: 150, viewHeight: 160,
                                          cellWidth: 8, cellHeight: 16, cols: 80, rows: 10)
        XCTAssertEqual(hit.col, 2)
        XCTAssertEqual(hit.row, 0)
        let bottomRight = TerminalLinkDetect.cell(atX: 9999, y: -5, viewHeight: 160,
                                                  cellWidth: 8, cellHeight: 16, cols: 80, rows: 10)
        XCTAssertEqual(bottomRight.col, 79)
        XCTAssertEqual(bottomRight.row, 9)
    }
}
