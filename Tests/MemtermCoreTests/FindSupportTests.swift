import XCTest
@testable import MemtermCore

final class FindSupportTests: XCTestCase {

    // MARK: - Match counter label

    func testZeroTotalReadsNoMatches() {
        XCTAssertEqual(FindSupport.matchCountLabel(index: 0, total: 0), "no matches")
        // A nonsensical current index without matches still reads as none.
        XCTAssertEqual(FindSupport.matchCountLabel(index: 3, total: 0), "no matches")
    }

    // Council #7: the counter reads "N of M" — a position, not a fraction.
    func testCurrentIndexOverTotal() {
        XCTAssertEqual(FindSupport.matchCountLabel(index: 1, total: 1), "1 of 1")
        XCTAssertEqual(FindSupport.matchCountLabel(index: 2, total: 14), "2 of 14")
    }

    func testNoCurrentMatchShowsTotalAsCount() {
        // index 0 with matches present: live output scrolled the last jump away.
        XCTAssertEqual(FindSupport.matchCountLabel(index: 0, total: 14), "14 matches")
        XCTAssertEqual(FindSupport.matchCountLabel(index: 0, total: 1), "1 match")
    }

    func testSaturatedTotalShowsCapWithPlus() {
        XCTAssertEqual(FindSupport.matchCountLabel(index: 7, total: 1000), "7 of 1000+")
        XCTAssertEqual(FindSupport.matchCountLabel(index: 0, total: 1000), "1000+ matches")
    }

    func testCustomLimit() {
        XCTAssertEqual(FindSupport.matchCountLabel(index: 1, total: 50, limit: 50), "1 of 50+")
        XCTAssertEqual(FindSupport.matchCountLabel(index: 1, total: 49, limit: 50), "1 of 49")
    }

    // MARK: - ⌘F prefill from selection

    func testSingleLineSelectionPrefills() {
        XCTAssertEqual(FindSupport.prefillTerm(fromSelection: "make test"), "make test")
    }

    func testNilAndEmptySelectionsDoNotPrefill() {
        XCTAssertNil(FindSupport.prefillTerm(fromSelection: nil))
        XCTAssertNil(FindSupport.prefillTerm(fromSelection: ""))
    }

    func testMultilineSelectionDoesNotPrefill() {
        XCTAssertNil(FindSupport.prefillTerm(fromSelection: "one\ntwo"))
        XCTAssertNil(FindSupport.prefillTerm(fromSelection: "one\r\ntwo"))
        XCTAssertNil(FindSupport.prefillTerm(fromSelection: "trailing\n"))
    }

    func testOverlongSelectionDoesNotPrefill() {
        let long = String(repeating: "x", count: 201)
        XCTAssertNil(FindSupport.prefillTerm(fromSelection: long))
        let exactlyAtCap = String(repeating: "x", count: 200)
        XCTAssertEqual(FindSupport.prefillTerm(fromSelection: exactlyAtCap), exactlyAtCap)
    }

    func testInteriorWhitespaceIsPreserved() {
        XCTAssertEqual(FindSupport.prefillTerm(fromSelection: "  padded  "), "  padded  ")
    }
}
