import XCTest
@testable import MemtermCore

/// Which workspaces appear as chips, and which appear under Parked.
///
/// Founder ask 2026-10-02: "parked should not show on the workspaces tabs
/// after its parked", with the parked ones reachable from a Parked section of
/// the menu instead. So the bar and that section partition the workspaces
/// between them.
///
/// The one subtlety is the active workspace. `workspaceEmptiedByUserClose`
/// parks a workspace while `activeWorkspaceId` may still name it — its own
/// comment says so, because the switch away is deferred. A naive "hide
/// everything parked" would blank the bar's active chip for that moment, so
/// the active workspace is always shown, parked or not.
final class WorkspaceVisibilityTests: XCTestCase {

    private func row(_ id: String, parked: Bool, ord: Int = 0) -> WorkspaceRow {
        WorkspaceRow(id: id, name: id.uppercased(), color: "#888888", ord: ord, isParked: parked)
    }

    func testParkedWorkspacesLeaveTheBar() {
        let list = [row("a", parked: false, ord: 0),
                    row("b", parked: true, ord: 1),
                    row("c", parked: false, ord: 2)]
        XCTAssertEqual(WorkspaceVisibility.barRows(list, activeId: "a").map(\.id), ["a", "c"])
        XCTAssertEqual(WorkspaceVisibility.parkedRows(list, activeId: "a").map(\.id), ["b"])
    }

    func testTheActiveWorkspaceIsShownEvenWhileItIsStillMarkedParked() {
        // The transient in `workspaceEmptiedByUserClose`: parked, but still
        // active because the switch away has not run yet.
        let list = [row("a", parked: true, ord: 0), row("b", parked: false, ord: 1)]
        XCTAssertEqual(WorkspaceVisibility.barRows(list, activeId: "a").map(\.id), ["a", "b"],
                       "the active workspace never vanishes from its own bar")
        XCTAssertEqual(WorkspaceVisibility.parkedRows(list, activeId: "a").map(\.id), [],
                       "and it is not offered under Parked at the same time")
    }

    func testEveryWorkspaceAppearsInExactlyOnePlace() {
        // The property that matters: no workspace can become unreachable by
        // falling between the bar and the Parked section.
        for activeIndex in 0 ..< 4 {
            for mask in 0 ..< 16 {
                let list = (0 ..< 4).map { i in
                    row("w\(i)", parked: mask & (1 << i) != 0, ord: i)
                }
                let active = "w\(activeIndex)"
                let bar = WorkspaceVisibility.barRows(list, activeId: active).map(\.id)
                let parked = WorkspaceVisibility.parkedRows(list, activeId: active).map(\.id)
                XCTAssertEqual(Set(bar).union(parked).count, 4,
                               "mask \(mask), active \(active): every workspace is somewhere")
                XCTAssertTrue(Set(bar).isDisjoint(with: Set(parked)),
                              "mask \(mask), active \(active): and never in both")
            }
        }
    }

    func testOrderIsPreservedInBothLists() {
        let list = [row("a", parked: true, ord: 0),
                    row("b", parked: false, ord: 1),
                    row("c", parked: true, ord: 2),
                    row("d", parked: false, ord: 3)]
        XCTAssertEqual(WorkspaceVisibility.barRows(list, activeId: "b").map(\.id), ["b", "d"])
        XCTAssertEqual(WorkspaceVisibility.parkedRows(list, activeId: "b").map(\.id), ["a", "c"],
                       "Parked keeps the store's order, so the list does not shuffle between opens")
    }

    func testAllParkedButOneActiveStillLeavesTheBarNonEmpty() {
        // The app always has a window, so the bar must always have a chip.
        let list = [row("a", parked: true, ord: 0), row("b", parked: true, ord: 1)]
        XCTAssertEqual(WorkspaceVisibility.barRows(list, activeId: "b").map(\.id), ["b"])
    }

    func testAnActiveIdThatNamesNothingDoesNotCrashOrHideEverything() {
        // Defensive: a stale active id (a forgotten workspace, mid-launch)
        // must not take the whole bar down with it.
        let list = [row("a", parked: false, ord: 0), row("b", parked: true, ord: 1)]
        XCTAssertEqual(WorkspaceVisibility.barRows(list, activeId: "gone").map(\.id), ["a"])
        XCTAssertEqual(WorkspaceVisibility.parkedRows(list, activeId: "gone").map(\.id), ["b"])
    }
}
