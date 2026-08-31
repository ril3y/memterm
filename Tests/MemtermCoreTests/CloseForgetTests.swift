import XCTest
@testable import MemtermCore

// FR-56/57 at the store level: memory follows intent. A user-initiated close
// forgets (rows AND bytes, immediately); quit keeps; workspace switch/park
// keeps; "Forget Everything" leaves an empty-but-working store.

final class CloseForgetTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var scrollbackDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-forget-tests-\(UUID().uuidString)")
        scrollbackDir = tempDir.appendingPathComponent("scrollback")
        try FileManager.default.createDirectory(at: scrollbackDir,
                                                withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("state.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Two windows in Default (t1: split p1+p2, t2: single p3) and one window
    /// in workspace B (t3: single p4), with scrollback files for every pane.
    private func populate(_ store: StateStore) throws {
        store.createWorkspace(id: "wsB", name: "B", color: "#0a84ff")
        let t1 = TabSnap(id: "t1", title: "one",
                         tree: .split(vertical: true, ratio: 0.5,
                                      first: .pane("p1"), second: .pane("p2")),
                         panes: [
                            PaneSnap(id: "p1", shell: "/bin/zsh", cwd: "/tmp", cwdSource: "kernel"),
                            PaneSnap(id: "p2", shell: "/bin/zsh", cwd: "/usr", cwdSource: "kernel"),
                         ])
        let t2 = TabSnap(id: "t2", title: "two", tree: .pane("p3"), panes: [
            PaneSnap(id: "p3", shell: "/bin/zsh", cwd: "/opt", cwdSource: "kernel"),
        ])
        store.saveTopology([
            WindowSnap(id: "t1", frame: "0,0,900,600", focusedTab: "t1", tabs: [t1, t2]),
        ], forWorkspaces: [StateStore.defaultWorkspaceId])
        let t3 = TabSnap(id: "t3", title: "b", tree: .pane("p4"), panes: [
            PaneSnap(id: "p4", shell: "/bin/zsh", cwd: "/var", cwdSource: "kernel"),
        ])
        store.saveTopology([
            WindowSnap(id: "t3", frame: "5,5,800,500", focusedTab: "t3", tabs: [t3],
                       workspaceId: "wsB"),
        ], forWorkspaces: ["wsB"])
        store.upsertSnapshot("p1", exe: "/usr/bin/ssh", argv: ["ssh", "host"], pid: 11,
                             adapter: "ssh", adapterState: [:])
        store.upsertSnapshot("p3", exe: "/usr/bin/tail", argv: ["tail", "-f", "x"], pid: 12,
                             adapter: "watcher", adapterState: [:])
        store.barrier()
        for paneId in ["p1", "p2", "p3", "p4"] {
            try "scrollback \(paneId)".write(
                to: ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId),
                atomically: true, encoding: .utf8)
        }
    }

    private func fileExists(_ paneId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId).path)
    }

    // MARK: FR-56 — close forgets, quit keeps

    /// The store analog of ⌘W on a tab: forgetTabs purges the tab's rows, its
    /// panes, their snapshots, its now-empty window row, and its panes' bytes
    /// on disk — and touches nothing else.
    func testCloseForgetPurgesExactlyTheClosedTab() throws {
        let store = StateStore(url: dbURL)
        try populate(store)

        store.forgetTabs(["t2"], scrollbackDir: scrollbackDir)
        store.barrier()

        XCTAssertFalse(fileExists("p3"), "closed tab's scrollback bytes must be deleted")
        XCTAssertTrue(fileExists("p1"))
        XCTAssertTrue(fileExists("p2"))
        XCTAssertTrue(fileExists("p4"), "other workspaces' files must survive")

        let restored = store.loadState(workspaceId: StateStore.defaultWorkspaceId)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].tabs.count, 1, "t2 must never restore")
        XCTAssertEqual(restored[0].tabs[0].title, "one")
        XCTAssertNil(restored[0].tabs[0].panes["p3"])
        // The surviving tab's snapshot is intact; t2's is gone.
        XCTAssertEqual(restored[0].tabs[0].panes["p1"]?.snapshot?.adapter, "ssh")
        XCTAssertEqual(store.snapshotCount(), 1)
        // Workspace B untouched.
        XCTAssertEqual(store.loadState(workspaceId: "wsB").count, 1)
    }

    /// Closing the last tab of a window removes the window row too (a window
    /// with no tabs describes nothing and must not linger).
    func testClosingLastTabRemovesTheWindowRow() throws {
        let store = StateStore(url: dbURL)
        try populate(store)

        store.forgetTabs(["t3"], scrollbackDir: scrollbackDir)
        store.barrier()

        XCTAssertTrue(store.loadState(workspaceId: "wsB").isEmpty)
        XCTAssertFalse(fileExists("p4"))
        // Default's window row survives.
        XCTAssertEqual(store.counts().windows, 1)
    }

    /// Quit is "put it down": no forget call happens, and reopening the store
    /// (a relaunch) restores everything that was open.
    func testQuitKeepsEverything() throws {
        var store: StateStore? = StateStore(url: dbURL)
        try populate(store!)
        store = nil  // normal quit: connection closes, rows stay

        let relaunched = StateStore(url: dbURL)
        XCTAssertEqual(relaunched.loadState(workspaceId: StateStore.defaultWorkspaceId)[0]
            .tabs.count, 2)
        XCTAssertEqual(relaunched.loadState(workspaceId: "wsB").count, 1)
        for paneId in ["p1", "p2", "p3", "p4"] {
            XCTAssertTrue(fileExists(paneId))
        }
    }

    /// Workspace switch/park closes windows too, but through scoped saves and
    /// setWorkspaceParked — never a forget. Rows and bytes must all survive a
    /// park plus a capture of the remaining open workspace.
    func testWorkspaceSwitchAndParkDoNotForget() throws {
        let store = StateStore(url: dbURL)
        try populate(store)

        // Park B (its window closes on screen; the journal keeps everything).
        store.setWorkspaceParked("wsB", parked: true)
        // The next capture covers only the still-open workspace — exactly what
        // the app's scoped saves do after a switch or park.
        store.saveTopology([
            WindowSnap(id: "t1", frame: "0,0,900,600", focusedTab: "t1", tabs: [
                TabSnap(id: "t1", title: "one",
                        tree: .split(vertical: true, ratio: 0.5,
                                     first: .pane("p1"), second: .pane("p2")),
                        panes: [
                            PaneSnap(id: "p1", shell: "/bin/zsh", cwd: "/tmp", cwdSource: "kernel"),
                            PaneSnap(id: "p2", shell: "/bin/zsh", cwd: "/usr", cwdSource: "kernel"),
                        ]),
                TabSnap(id: "t2", title: "two", tree: .pane("p3"), panes: [
                    PaneSnap(id: "p3", shell: "/bin/zsh", cwd: "/opt", cwdSource: "kernel"),
                ]),
            ]),
        ], forWorkspaces: [StateStore.defaultWorkspaceId])
        store.purgeOrphanScrollback(dir: scrollbackDir)
        store.barrier()

        let parked = store.loadState(workspaceId: "wsB")
        XCTAssertEqual(parked.count, 1, "parked workspace rows must survive")
        XCTAssertEqual(parked[0].tabs[0].panes["p4"]?.cwd, "/var")
        XCTAssertTrue(fileExists("p4"), "parked workspace scrollback must survive")
    }

    // MARK: FR-57 — forget pane

    func testForgetPanePurgesExactlyThatPanesRowsAndFile() throws {
        let store = StateStore(url: dbURL)
        try populate(store)

        store.forgetPanes(["p1"], scrollbackDir: scrollbackDir)
        store.barrier()

        XCTAssertFalse(fileExists("p1"))
        XCTAssertTrue(fileExists("p2"))
        XCTAssertTrue(fileExists("p3"))
        XCTAssertTrue(fileExists("p4"))

        let restored = store.loadState(workspaceId: StateStore.defaultWorkspaceId)
        // The tab stays (the pane is still open on screen; the next capture
        // re-adds its row with a fresh trail) — only p1's rows are gone now.
        XCTAssertEqual(restored[0].tabs.count, 2)
        let tab1 = restored[0].tabs.first { $0.title == "one" }
        XCTAssertNil(tab1?.panes["p1"])
        XCTAssertNotNil(tab1?.panes["p2"])
        // p1's snapshot went with it; p3's stays.
        XCTAssertEqual(store.snapshotCount(), 1)
    }

    // MARK: FR-45/57 — forget everything

    /// The app path: release the store, purge the state dir contents, open a
    /// fresh store. The result must be empty but fully working — a Default
    /// workspace, writable, and re-capture lands cleanly.
    func testForgetEverythingLeavesAnEmptyButWorkingStore() throws {
        var store: StateStore? = StateStore(url: dbURL)
        try populate(store!)
        store = nil  // connection must be closed before the purge

        StateStore.purgeAll(dbURL: dbURL, scrollbackDir: scrollbackDir)

        // Nothing left on disk: db, sidecars, generations, scrollback bytes.
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dbURL.path))
        XCTAssertFalse(fm.fileExists(atPath: dbURL.path + ".gen-1"))
        let leftovers = try fm.contentsOfDirectory(atPath: scrollbackDir.path)
        XCTAssertTrue(leftovers.isEmpty, "scrollback bytes must be gone, got \(leftovers)")

        // A fresh store is empty but fully functional.
        let fresh = StateStore(url: dbURL)
        XCTAssertTrue(fresh.loadState().isEmpty)
        XCTAssertEqual(fresh.counts().panes, 0)
        XCTAssertEqual(fresh.listWorkspaces().map(\.id), [StateStore.defaultWorkspaceId])

        // Re-capture of the currently-open layout continues cleanly.
        fresh.saveTopology([
            WindowSnap(id: "t9", frame: "0,0,900,600", focusedTab: "t9", tabs: [
                TabSnap(id: "t9", title: "live", tree: .pane("p9"), panes: [
                    PaneSnap(id: "p9", shell: "/bin/zsh", cwd: "/tmp", cwdSource: "kernel"),
                ]),
            ]),
        ], forWorkspaces: [StateStore.defaultWorkspaceId])
        fresh.barrier()
        XCTAssertEqual(fresh.counts().panes, 1)
        XCTAssertEqual(fresh.loadState()[0].tabs[0].panes["p9"]?.cwd, "/tmp")
    }

    /// forgetPanes/forgetTabs with ids that have no rows (a pane closed before
    /// its first capture) must not throw, delete other rows, or leave the
    /// store degraded.
    func testForgetUnknownIdsIsHarmless() throws {
        let store = StateStore(url: dbURL)
        try populate(store)

        store.forgetPanes(["never-captured"], scrollbackDir: scrollbackDir)
        store.forgetTabs(["nor-this-tab"], scrollbackDir: scrollbackDir)
        store.forgetPanes([], scrollbackDir: scrollbackDir)
        store.forgetTabs([], scrollbackDir: scrollbackDir)
        store.barrier()

        XCTAssertEqual(store.counts().panes, 4)
        XCTAssertEqual(store.counts().windows, 2)
        for paneId in ["p1", "p2", "p3", "p4"] {
            XCTAssertTrue(fileExists(paneId))
        }
    }
}
