import XCTest
@testable import MemtermCore

final class WorkspaceActivityTests: XCTestCase {

    private func center() -> WorkspaceActivityCenter {
        WorkspaceActivityCenter(decayInterval: 1.5, coalesceInterval: 0.25)
    }

    func testIdleByDefault() {
        let c = center()
        XCTAssertEqual(c.state(of: "a", at: 0), .idle)
        XCTAssertNil(c.nextDecay(after: 0))
    }

    func testHiddenWorkspaceOutputGoesActiveThenUnseen() {
        var c = center()
        XCTAssertTrue(c.recordOutput(workspace: "a", at: 10, isActiveWorkspace: false))
        XCTAssertEqual(c.state(of: "a", at: 10.5), .active)
        XCTAssertEqual(c.state(of: "a", at: 11.5), .unseen)
        XCTAssertEqual(c.state(of: "a", at: 500), .unseen,
                       "unseen persists until the workspace is switched to")
    }

    func testActiveWorkspaceNeverIndicates() {
        var c = center()
        XCTAssertFalse(c.recordOutput(workspace: "a", at: 10, isActiveWorkspace: true))
        XCTAssertEqual(c.state(of: "a", at: 10), .idle)
    }

    func testOutputInNowActiveWorkspaceClearsStaleState() {
        var c = center()
        _ = c.recordOutput(workspace: "a", at: 10, isActiveWorkspace: false)
        // The workspace became active without recordSwitched (missed event):
        // active-workspace output self-heals and asks for one repaint.
        XCTAssertTrue(c.recordOutput(workspace: "a", at: 12, isActiveWorkspace: true))
        XCTAssertEqual(c.state(of: "a", at: 12), .idle)
    }

    func testSwitchingClearsOnlyThatWorkspace() {
        var c = center()
        _ = c.recordOutput(workspace: "a", at: 10, isActiveWorkspace: false)
        _ = c.recordOutput(workspace: "b", at: 10, isActiveWorkspace: false)
        c.recordSwitched(to: "a")
        XCTAssertEqual(c.state(of: "a", at: 10.1), .idle)
        XCTAssertEqual(c.state(of: "b", at: 10.1), .active, "b keeps its mark")
    }

    func testCoalescingIsPerWorkspace() {
        var c = center()
        XCTAssertTrue(c.recordOutput(workspace: "a", at: 10.0, isActiveWorkspace: false))
        XCTAssertFalse(c.recordOutput(workspace: "a", at: 10.1, isActiveWorkspace: false),
                       "same workspace, inside the coalesce window")
        XCTAssertTrue(c.recordOutput(workspace: "b", at: 10.1, isActiveWorkspace: false),
                      "another workspace publishes independently")
        XCTAssertTrue(c.recordOutput(workspace: "a", at: 10.25, isActiveWorkspace: false))
    }

    func testCoalescedOutputStillAdvancesDecayClock() {
        var c = center()
        _ = c.recordOutput(workspace: "a", at: 10.0, isActiveWorkspace: false)
        XCTAssertFalse(c.recordOutput(workspace: "a", at: 10.1, isActiveWorkspace: false))
        XCTAssertEqual(c.state(of: "a", at: 11.55), .active)
        XCTAssertEqual(c.nextDecay(after: 10.2), 11.6)
    }

    func testNextDecayIsTheEarliestAcrossWorkspaces() {
        var c = center()
        _ = c.recordOutput(workspace: "a", at: 10.0, isActiveWorkspace: false)
        _ = c.recordOutput(workspace: "b", at: 10.4, isActiveWorkspace: false)
        XCTAssertEqual(c.nextDecay(after: 10.5), 11.5, "a decays first")
        XCTAssertEqual(c.nextDecay(after: 11.6), 11.9, "then only b is pending")
        XCTAssertNil(c.nextDecay(after: 12.0))
    }

    func testRemoveWorkspaceDropsItsState() {
        var c = center()
        _ = c.recordOutput(workspace: "a", at: 10, isActiveWorkspace: false)
        c.removeWorkspace("a")
        XCTAssertEqual(c.state(of: "a", at: 10.1), .idle)
        XCTAssertNil(c.nextDecay(after: 10.1))
    }
}
