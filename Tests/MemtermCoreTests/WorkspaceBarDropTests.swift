import XCTest
@testable import MemtermCore

/// Where a dragged tab lands when it is dropped on the workspace bar.
///
/// This is deliberately pure and axis-agnostic. The bar is horizontal today
/// and an Appearance option will stack it vertically (founder ask
/// 2026-10-02), and the drop rules are identical in both: the only thing that
/// changes is which coordinate runs along the bar. Writing it against an axis
/// now means the sidebar inherits drop support instead of needing its own
/// copy of these rules.
///
/// The rules, in the order they resolve:
///   1. A point outside the bar is not a drop at all.
///   2. A point inside a chip targets that workspace.
///   3. A point in a gap BETWEEN chips targets the nearest chip, because a
///      few pixels of inter-chip gap is a near miss, not a request for a new
///      workspace.
///   4. A point anywhere in the bar beyond the run of chips is empty bar:
///      that is the "make me a new workspace" gesture.
final class WorkspaceBarDropTests: XCTestCase {

    /// A horizontal bar: three chips left to right, with gaps, in a bar that
    /// extends well past the last chip.
    private let horizontalBar = CGRect(x: 0, y: 0, width: 400, height: 28)
    private var horizontalChips: [(id: String, frame: CGRect)] {
        [("w1", CGRect(x: 8, y: 2, width: 90, height: 24)),
         ("w2", CGRect(x: 104, y: 2, width: 90, height: 24)),
         ("w3", CGRect(x: 200, y: 2, width: 90, height: 24))]
    }

    func testAPointOutsideTheBarIsNotADrop() {
        for point in [CGPoint(x: -5, y: 14), CGPoint(x: 405, y: 14),
                      CGPoint(x: 200, y: -3), CGPoint(x: 200, y: 40)] {
            XCTAssertEqual(WorkspaceBarDrop.target(at: point, bounds: horizontalBar,
                                                   chips: horizontalChips, axis: .horizontal),
                           .outside,
                           "\(point) is not over the bar")
        }
    }

    func testAPointInsideAChipTargetsThatWorkspace() {
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 50, y: 14), bounds: horizontalBar,
                                               chips: horizontalChips, axis: .horizontal),
                       .workspace(id: "w1"))
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 150, y: 14), bounds: horizontalBar,
                                               chips: horizontalChips, axis: .horizontal),
                       .workspace(id: "w2"))
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 245, y: 14), bounds: horizontalBar,
                                               chips: horizontalChips, axis: .horizontal),
                       .workspace(id: "w3"))
    }

    func testAGapBetweenChipsIsANearMissNotANewWorkspace() {
        // x = 101 is in the 6pt gap between w1 (ends 98) and w2 (starts 104),
        // and closer to w1's trailing edge.
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 100, y: 14), bounds: horizontalBar,
                                               chips: horizontalChips, axis: .horizontal),
                       .workspace(id: "w1"),
                       "a hair past w1 is still w1, not a request for a new workspace")
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 103, y: 14), bounds: horizontalBar,
                                               chips: horizontalChips, axis: .horizontal),
                       .workspace(id: "w2"),
                       "and a hair before w2 is w2")
    }

    func testEmptyBarBeyondTheChipsAsksForANewWorkspace() {
        // The founder's gesture: drag a tab to the bare stretch of bar.
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 350, y: 14), bounds: horizontalBar,
                                               chips: horizontalChips, axis: .horizontal),
                       .newWorkspace)
        // Before the first chip counts too — it is just as empty, and a bar
        // that grows right-to-left (or a vertical bar) would otherwise lose
        // the gesture entirely.
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 2, y: 14), bounds: horizontalBar,
                                               chips: horizontalChips, axis: .horizontal),
                       .newWorkspace)
    }

    func testABarWithNoChipsIsAllNewWorkspace() {
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 200, y: 14), bounds: horizontalBar,
                                               chips: [], axis: .horizontal),
                       .newWorkspace)
    }

    // MARK: - The vertical sidebar, same rules, other axis

    /// A vertical bar in AppKit's bottom-up coordinates: w1 at the TOP means
    /// the largest y. The rules must not care which direction the stack
    /// grows, which is the point of resolving against the chips' own extent
    /// rather than against an assumed leading edge.
    private let verticalBar = CGRect(x: 0, y: 0, width: 160, height: 500)
    private var verticalChips: [(id: String, frame: CGRect)] {
        [("w1", CGRect(x: 4, y: 460, width: 152, height: 32)),
         ("w2", CGRect(x: 4, y: 424, width: 152, height: 32)),
         ("w3", CGRect(x: 4, y: 388, width: 152, height: 32))]
    }

    func testTheVerticalSidebarResolvesChipsOnItsOwnAxis() {
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 80, y: 470), bounds: verticalBar,
                                               chips: verticalChips, axis: .vertical),
                       .workspace(id: "w1"))
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 80, y: 400), bounds: verticalBar,
                                               chips: verticalChips, axis: .vertical),
                       .workspace(id: "w3"))
    }

    func testTheVerticalSidebarsEmptyRunBelowTheChipsAsksForANewWorkspace() {
        // The long bare stretch under a short stack: the same gesture as
        // dragging past the right-hand end of the horizontal bar.
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 80, y: 120), bounds: verticalBar,
                                               chips: verticalChips, axis: .vertical),
                       .newWorkspace)
    }

    func testTheVerticalSidebarsGapsAreStillNearMisses() {
        // y = 458 sits in the 4pt gap between w1 (bottom 460) and w2 (top 456).
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 80, y: 458), bounds: verticalBar,
                                               chips: verticalChips, axis: .vertical),
                       .workspace(id: "w1"))
    }

    /// The cross-axis still bounds the hit: a point level with a chip but
    /// outside the bar's width is not over the bar.
    func testTheCrossAxisStillBoundsTheDrop() {
        XCTAssertEqual(WorkspaceBarDrop.target(at: CGPoint(x: 200, y: 470), bounds: verticalBar,
                                               chips: verticalChips, axis: .vertical),
                       .outside)
    }
}
