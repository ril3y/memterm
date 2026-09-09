import XCTest
@testable import MemtermCore

// Founder bug (2026-09-09): chrome text ignored Appearance › Size. The
// metrics are pure so the scaling contract is pinned headlessly; the
// chip-pill-hierarchy probe leg gates the rendered result.
final class ChromeMetricsTests: XCTestCase {
    /// The default terminal size reproduces the hand-tuned design exactly —
    /// no visual change for anyone who never touched the setting.
    func testReferenceSizeIsTheOriginalDesign() {
        let m = ChromeMetrics.derived(fromTerminalFontSize: 13)
        XCTAssertEqual(m.pillFontSize, 11)
        XCTAssertEqual(m.chipFontSize, 10)
        XCTAssertEqual(m.chipSuffixFontSize, 9)
        XCTAssertEqual(m.tabStripHeight, 30)
        XCTAssertEqual(m.workspaceBarHeight, 26)
        XCTAssertEqual(m.chipHeight, 19)
        XCTAssertEqual(m.chipBaselineOffset, 3.85, accuracy: 0.001)
        XCTAssertEqual(m.scale, 1, accuracy: 0.001)
    }

    /// THE bug: a bigger terminal font must grow the chrome text.
    func testLargerTerminalFontGrowsChrome() {
        let m = ChromeMetrics.derived(fromTerminalFontSize: 20)
        XCTAssertEqual(m.pillFontSize, 17)   // round(11 * 20/13)
        XCTAssertEqual(m.chipFontSize, 16)
        XCTAssertGreaterThan(m.tabStripHeight, 30)
        XCTAssertGreaterThan(m.workspaceBarHeight, 26)
        XCTAssertGreaterThan(m.chipHeight, 19)
    }

    /// Small terminal fonts floor the chrome instead of shrinking it into
    /// illegibility.
    func testTinyTerminalFontFloorsChrome() {
        let m = ChromeMetrics.derived(fromTerminalFontSize: 6)
        XCTAssertEqual(m.pillFontSize, ChromeMetrics.minimumPillSize)
        XCTAssertEqual(m.chipFontSize, ChromeMetrics.minimumPillSize - 1)
        XCTAssertLessThanOrEqual(m.tabStripHeight, 30)
    }

    /// Council #10 hierarchy holds at EVERY size the config accepts: chips
    /// strictly below pills in font AND height, suffix below chip. The probe
    /// leg asserts the rendered version; this pins the math it rides on.
    func testHierarchyHoldsAcrossSizes() {
        var size = 5.0
        while size <= 72 {
            let m = ChromeMetrics.derived(fromTerminalFontSize: size)
            XCTAssertLessThan(m.chipFontSize, m.pillFontSize, "size \(size)")
            XCTAssertLessThan(m.chipSuffixFontSize, m.chipFontSize, "size \(size)")
            XCTAssertLessThan(m.chipHeight, m.tabStripHeight - 7, "size \(size)")
            XCTAssertLessThan(m.chipHeight, m.workspaceBarHeight, "size \(size)")
            XCTAssertEqual(m.pillFontSize, m.pillFontSize.rounded(), "whole points at \(size)")
            size += 0.5
        }
    }

    func testMonotonicInTerminalSize() {
        var previous = ChromeMetrics.derived(fromTerminalFontSize: 4)
        for size in stride(from: 5.0, through: 72, by: 1) {
            let m = ChromeMetrics.derived(fromTerminalFontSize: size)
            XCTAssertGreaterThanOrEqual(m.pillFontSize, previous.pillFontSize)
            XCTAssertGreaterThanOrEqual(m.tabStripHeight, previous.tabStripHeight)
            previous = m
        }
    }
}
