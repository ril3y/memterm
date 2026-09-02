import XCTest
@testable import MemtermCore

final class TabStripLayoutTests: XCTestCase {

    func testSingleTabCapsAtMaxWidth() {
        let layout = TabStripLayout(available: 900, count: 1)
        XCTAssertEqual(layout.tabWidth, TabStripLayout.maxTabWidth)
        XCTAssertFalse(layout.needsScroll)
    }

    // Council #4: tabs use the strip width — the cap sits at 360pt so long
    // host:path titles get room without a lone tab spanning a huge window.
    func testMaxWidthIsTheCouncilCap() {
        XCTAssertEqual(TabStripLayout.maxTabWidth, 360)
        // Two tabs in a wide strip both grow past the old 220 cap…
        let two = TabStripLayout(available: 900, count: 2)
        XCTAssertEqual(two.tabWidth, 360)
        // …and share equally below it.
        let squeezed = TabStripLayout(available: 500, count: 2)
        XCTAssertEqual(squeezed.tabWidth, (500 - TabStripLayout.tabGap) / 2,
                       accuracy: 0.001)
    }

    func testTabsShareWidthEqually() {
        let layout = TabStripLayout(available: 600, count: 4)
        let gaps = 3 * TabStripLayout.tabGap
        XCTAssertEqual(layout.tabWidth, (600 - gaps) / 4, accuracy: 0.001)
        XCTAssertFalse(layout.needsScroll)
        XCTAssertEqual(layout.contentWidth, 600, accuracy: 0.001)
    }

    func testSqueezeStopsAtFloorAndScrolls() {
        let layout = TabStripLayout(available: 300, count: 10)
        XCTAssertEqual(layout.tabWidth, TabStripLayout.minTabWidth)
        XCTAssertTrue(layout.needsScroll)
        XCTAssertGreaterThan(layout.contentWidth, 300)
    }

    func testZeroTabs() {
        let layout = TabStripLayout(available: 500, count: 0)
        XCTAssertEqual(layout.tabWidth, 0)
        XCTAssertEqual(layout.contentWidth, 0)
        XCTAssertNil(layout.hitTest(x: 10))
    }

    func testHitTestInsideTabsAndGaps() {
        let layout = TabStripLayout(available: 600, count: 3)
        XCTAssertEqual(layout.hitTest(x: 1), 0)
        XCTAssertEqual(layout.hitTest(x: layout.tabWidth - 1), 0)
        // Just past the first tab's trailing edge but inside the gap: no tab.
        XCTAssertNil(layout.hitTest(x: layout.tabWidth + TabStripLayout.tabGap / 2))
        let secondStart = layout.xOrigin(of: 1)
        XCTAssertEqual(layout.hitTest(x: secondStart + 1), 1)
        XCTAssertEqual(layout.hitTest(x: layout.xOrigin(of: 2) + 1), 2)
        // Trailing empty space: background.
        XCTAssertNil(layout.hitTest(x: layout.contentWidth + 5))
        XCTAssertNil(layout.hitTest(x: -3))
    }

    func testDropIndexClamps() {
        let layout = TabStripLayout(available: 600, count: 3)
        XCTAssertEqual(layout.dropIndex(forDragCenterX: -50), 0)
        XCTAssertEqual(layout.dropIndex(forDragCenterX: layout.xOrigin(of: 1) + 2), 1)
        XCTAssertEqual(layout.dropIndex(forDragCenterX: 10_000), 2)
    }

    func testContrastFlipMatchesPillRule() {
        XCTAssertTrue(TabTint.useDarkText(red: 1, green: 1, blue: 1))
        XCTAssertFalse(TabTint.useDarkText(red: 0, green: 0, blue: 0))
        // Yellow preset (#febc2e) reads dark text; blue (#0a84ff) light.
        XCTAssertTrue(TabTint.useDarkText(red: 0xfe / 255.0, green: 0xbc / 255.0,
                                          blue: 0x2e / 255.0))
        XCTAssertFalse(TabTint.useDarkText(red: 0x0a / 255.0, green: 0x84 / 255.0,
                                           blue: 0xff / 255.0))
    }

    func testReorderMove() {
        XCTAssertEqual(TabReorder.move([1, 2, 3, 4], from: 0, to: 2), [2, 3, 1, 4])
        XCTAssertEqual(TabReorder.move([1, 2, 3, 4], from: 3, to: 0), [4, 1, 2, 3])
        XCTAssertEqual(TabReorder.move([1, 2, 3], from: 1, to: 1), [1, 2, 3])
        XCTAssertEqual(TabReorder.move([1], from: 0, to: 5), [1])
    }
}
