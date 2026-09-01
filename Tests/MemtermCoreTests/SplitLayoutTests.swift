import XCTest
@testable import MemtermCore

// TESTING.md L2 seam (a): pure split layout. The headline invariant is the
// bug-1 regression: NO pane may be zero-sized in a non-zero container — the
// restored-split collapse presented 979/0 from launch because layout passed
// through a 0x0 container and re-expanded badly.
final class SplitLayoutTests: XCTestCase {
    private let twoPane = SplitNode.split(vertical: true, ratio: 0.5,
                                          first: .pane("a"), second: .pane("b"))
    private let nested = SplitNode.split(
        vertical: true, ratio: 0.6,
        first: .pane("a"),
        second: .split(vertical: false, ratio: 0.3,
                       first: .pane("b"), second: .pane("c")))

    func testNormalContainerTilesExactly() {
        let rects = SplitLayout.layout(tree: nested,
                                       container: CGRect(x: 0, y: 0, width: 1000, height: 600))
        XCTAssertEqual(rects.count, 3)
        let area = rects.values.reduce(0.0) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, 1000 * 600, accuracy: 0.5)
        XCTAssertEqual(rects["a"]!.width, 600, accuracy: 0.5)  // 0.6 of 1000
        XCTAssertEqual(rects["b"]!.height, 180, accuracy: 0.5) // 0.3 of 600
    }

    /// REGRESSION (founder bug 1, restored split collapse): a non-zero
    /// container must never produce a zero-sized pane — for any ratio,
    /// including the degenerate 0 and 1 a corrupted journal could carry.
    func testNoZeroPaneInNonZeroContainer() {
        for ratio in [0.0, 0.001, 0.5, 0.999, 1.0] {
            let tree = SplitNode.split(vertical: true, ratio: ratio,
                                       first: .pane("a"), second: .pane("b"))
            for container in [CGRect(x: 0, y: 0, width: 979, height: 583),
                              CGRect(x: 0, y: 0, width: 120, height: 90),
                              CGRect(x: 0, y: 0, width: 10, height: 10)] {
                let rects = SplitLayout.layout(tree: tree, container: container)
                for (id, rect) in rects {
                    XCTAssertGreaterThan(rect.width, 0,
                        "pane \(id) zero-wide at ratio \(ratio) in \(container)")
                    XCTAssertGreaterThan(rect.height, 0,
                        "pane \(id) zero-tall at ratio \(ratio) in \(container)")
                }
            }
        }
    }

    func testZeroContainerYieldsZeroRectsWithoutTrapping() {
        let rects = SplitLayout.layout(tree: nested, container: .zero)
        XCTAssertEqual(rects.count, 3)
        for rect in rects.values {
            XCTAssertEqual(rect.width, 0)
            XCTAssertEqual(rect.height, 0)
        }
    }

    func testTinyContainerSplitsInHalfRatherThanStarving() {
        // Below 2*minPaneSide the floor degrades to side/2: both children
        // still get half rather than one child being starved to zero.
        let rects = SplitLayout.layout(tree: twoPane,
                                       container: CGRect(x: 0, y: 0, width: 60, height: 60))
        XCTAssertEqual(rects["a"]!.width, 30, accuracy: 0.5)
        XCTAssertEqual(rects["b"]!.width, 30, accuracy: 0.5)
    }

    func testGarbageRatioIsContained() {
        let share = SplitLayout.clampedFirstShare(side: 800, ratio: .nan)
        XCTAssertEqual(share, 400, accuracy: 0.5)
        XCTAssertEqual(SplitLayout.clampedFirstShare(side: 0, ratio: 0.5), 0)
    }
}
