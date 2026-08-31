import SQLite3
import XCTest
@testable import MemtermCore

// Group G (FR-49..51) at the store level: schema migration, park/reopen
// round-trips, switcher ordering, and the forget path's file purge.

final class WorkspaceStoreTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-ws-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("state.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func snap(windowId: String, tabId: String, paneId: String, cwd: String,
                      workspaceId: String) -> WindowSnap {
        WindowSnap(id: windowId, frame: "0,0,900,600", focusedTab: tabId, tabs: [
            TabSnap(id: tabId, title: tabId, tree: .pane(paneId), panes: [
                PaneSnap(id: paneId, shell: "/bin/zsh", cwd: cwd, cwdSource: "kernel"),
            ]),
        ], workspaceId: workspaceId)
    }

    // MARK: Migration (v1 → v2)

    /// A v1 database (no workspaces table, no workspace_id columns) must open
    /// in place: a Default workspace is created and every existing tab/window
    /// is adopted into it — existing users' state survives the upgrade.
    func testMigrationAdoptsOrphanTabsIntoDefaultWorkspace() throws {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &raw), SQLITE_OK)
        let v1Schema = """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE windows (id TEXT PRIMARY KEY, frame TEXT, ord INTEGER,
                              focused_tab TEXT, updated_at INTEGER);
        CREATE TABLE tabs (id TEXT PRIMARY KEY, window_id TEXT, ord INTEGER,
                           title TEXT, split_tree TEXT, updated_at INTEGER);
        CREATE TABLE panes (id TEXT PRIMARY KEY, tab_id TEXT, shell TEXT,
                            cwd TEXT, cwd_source TEXT, updated_at INTEGER);
        CREATE TABLE pane_snapshot (pane_id TEXT PRIMARY KEY, exe TEXT, argv TEXT,
                                    pid INTEGER, adapter TEXT, adapter_state TEXT,
                                    updated_at INTEGER);
        INSERT INTO meta VALUES ('schema_version', '1');
        INSERT INTO windows VALUES ('w1', '10,20,980,640', 0, 't1', 0);
        INSERT INTO tabs VALUES ('t1', 'w1', 0, 'work', '{"pane":"p1"}', 0);
        INSERT INTO panes VALUES ('p1', 't1', '/bin/zsh', '/tmp', 'kernel', 0);
        """
        XCTAssertEqual(sqlite3_exec(raw, v1Schema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let store = StateStore(url: dbURL)
        XCTAssertEqual(store.getMeta("schema_version"), "2")

        let workspaces = store.listWorkspaces()
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].id, StateStore.defaultWorkspaceId)
        XCTAssertEqual(workspaces[0].name, "Default")
        XCTAssertFalse(workspaces[0].isParked)

        // The pre-workspace window/tab/pane were adopted, not dropped.
        let restored = store.loadState(workspaceId: StateStore.defaultWorkspaceId)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].tabs.count, 1)
        XCTAssertEqual(restored[0].tabs[0].panes["p1"]?.cwd, "/tmp")
        // And they are scoped: an unknown workspace holds nothing.
        XCTAssertTrue(store.loadState(workspaceId: "nope").isEmpty)
    }

    /// Migration is idempotent: reopening a v2 store must not duplicate the
    /// Default workspace or re-adopt tabs.
    func testMigrationIsIdempotentAcrossReopens() {
        var store: StateStore? = StateStore(url: dbURL)
        store?.createWorkspace(id: "wsB", name: "B", color: "#0a84ff")
        store?.saveTopology([snap(windowId: "bw", tabId: "bt", paneId: "bp", cwd: "/usr",
                                  workspaceId: "wsB")],
                            forWorkspaces: ["wsB"])
        store?.barrier()
        store = nil

        let reopened = StateStore(url: dbURL)
        let workspaces = reopened.listWorkspaces()
        XCTAssertEqual(workspaces.map(\.id), [StateStore.defaultWorkspaceId, "wsB"])
        // B's tab kept its workspace — it was not "adopted" into Default.
        XCTAssertEqual(reopened.loadState(workspaceId: "wsB").count, 1)
        XCTAssertTrue(reopened.loadState(workspaceId: StateStore.defaultWorkspaceId).isEmpty)
    }

    // MARK: Park / reopen (FR-51)

    func testParkReopenRoundTripPreservesTopologyAndCwds() {
        let store = StateStore(url: dbURL)
        store.createWorkspace(id: "wsB", name: "B", color: "#0a84ff")

        let tree = SplitNode.split(vertical: true, ratio: 0.4,
                                   first: .pane("bp1"), second: .pane("bp2"))
        let bWindow = WindowSnap(id: "bw", frame: "5,5,800,500", focusedTab: "bt", tabs: [
            TabSnap(id: "bt", title: "infra", tree: tree, panes: [
                PaneSnap(id: "bp1", shell: "/bin/zsh", cwd: "/var/log", cwdSource: "kernel"),
                PaneSnap(id: "bp2", shell: "/bin/bash", cwd: "/opt", cwdSource: "osc7"),
            ]),
        ], workspaceId: "wsB")
        store.saveTopology([bWindow], forWorkspaces: ["wsB"])
        store.upsertSnapshot("bp1", exe: "/usr/bin/ssh", argv: ["ssh", "host"], pid: 7,
                             adapter: "ssh", adapterState: [:])
        store.setWorkspaceParked("wsB", parked: true)
        store.barrier()

        // While B is parked, captures of the open workspace must not touch it.
        store.saveTopology([snap(windowId: "dw", tabId: "dt", paneId: "dp", cwd: "/tmp",
                                 workspaceId: StateStore.defaultWorkspaceId)],
                           forWorkspaces: [StateStore.defaultWorkspaceId])
        store.barrier()

        XCTAssertEqual(store.listWorkspaces().first { $0.id == "wsB" }?.isParked, true)
        let parked = store.loadState(workspaceId: "wsB")
        XCTAssertEqual(parked.count, 1)
        XCTAssertEqual(parked[0].frame, "5,5,800,500")
        XCTAssertEqual(parked[0].tabs[0].tree, tree)
        XCTAssertEqual(parked[0].tabs[0].panes["bp1"]?.cwd, "/var/log")
        XCTAssertEqual(parked[0].tabs[0].panes["bp2"]?.cwd, "/opt")
        // Adapter state stays journaled too (the reopen offers depend on it).
        XCTAssertEqual(parked[0].tabs[0].panes["bp1"]?.snapshot?.adapter, "ssh")

        // Reopen = unpark; the same rows feed the standard restore pipeline.
        store.setWorkspaceParked("wsB", parked: false)
        store.barrier()
        XCTAssertEqual(store.listWorkspaces().first { $0.id == "wsB" }?.isParked, false)
        XCTAssertEqual(store.loadState(workspaceId: "wsB")[0].tabs[0].tree, tree)
    }

    // MARK: Ordering

    func testWorkspaceOrderingFollowsCreation() {
        let store = StateStore(url: dbURL)
        store.createWorkspace(id: "wsB", name: "B", color: "#0a84ff")
        store.createWorkspace(id: "wsC", name: "C", color: "#28c840")
        store.barrier()

        let workspaces = store.listWorkspaces()
        XCTAssertEqual(workspaces.map(\.name), ["Default", "B", "C"])
        XCTAssertEqual(workspaces.map(\.ord), [0, 1, 2])

        store.renameWorkspace("wsB", name: "Infra")
        store.recolorWorkspace("wsB", color: "#ff5f57")
        store.barrier()
        let renamed = store.listWorkspaces()
        // Rename/recolor never reorder the switcher.
        XCTAssertEqual(renamed.map(\.name), ["Default", "Infra", "C"])
        XCTAssertEqual(renamed[1].color, "#ff5f57")
    }

    // MARK: Forget (FR-50/57)

    func testForgetWorkspacePurgesRowsAndScrollbackFiles() throws {
        let store = StateStore(url: dbURL)
        store.createWorkspace(id: "wsB", name: "B", color: "#0a84ff")
        store.saveTopology([snap(windowId: "dw", tabId: "dt", paneId: "dp", cwd: "/tmp",
                                 workspaceId: StateStore.defaultWorkspaceId)],
                           forWorkspaces: [StateStore.defaultWorkspaceId])
        let bWindow = WindowSnap(id: "bw", frame: "0,0,900,600", focusedTab: "bt", tabs: [
            TabSnap(id: "bt", title: "b", tree: .split(vertical: false, ratio: 0.5,
                                                       first: .pane("bp1"),
                                                       second: .pane("bp2")),
                    panes: [
                        PaneSnap(id: "bp1", shell: "/bin/zsh", cwd: "/usr", cwdSource: "kernel"),
                        PaneSnap(id: "bp2", shell: "/bin/zsh", cwd: "/opt", cwdSource: "kernel"),
                    ]),
        ], workspaceId: "wsB")
        store.saveTopology([bWindow], forWorkspaces: ["wsB"])
        store.upsertSnapshot("bp1", exe: "/usr/bin/tail", argv: ["tail", "-f", "x"], pid: 9,
                             adapter: "watcher", adapterState: [:])
        store.barrier()

        // Scrollback files for both workspaces' panes.
        let scrollbackDir = tempDir.appendingPathComponent("scrollback")
        try FileManager.default.createDirectory(at: scrollbackDir,
                                                withIntermediateDirectories: true)
        for paneId in ["dp", "bp1", "bp2"] {
            try "ghost \(paneId)".write(
                to: ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId),
                atomically: true, encoding: .utf8)
        }

        store.forgetWorkspace("wsB", scrollbackDir: scrollbackDir)
        store.barrier()

        // Forgetting deletes the bytes on disk, not just the index rows…
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(
            atPath: ScrollbackText.fileURL(dir: scrollbackDir, paneId: "bp1").path))
        XCTAssertFalse(fm.fileExists(
            atPath: ScrollbackText.fileURL(dir: scrollbackDir, paneId: "bp2").path))
        // …and never anyone else's.
        XCTAssertTrue(fm.fileExists(
            atPath: ScrollbackText.fileURL(dir: scrollbackDir, paneId: "dp").path))

        // Every row of the forgotten workspace is gone, snapshots included.
        XCTAssertEqual(store.listWorkspaces().map(\.id), [StateStore.defaultWorkspaceId])
        XCTAssertTrue(store.loadState(workspaceId: "wsB").isEmpty)
        XCTAssertEqual(store.snapshotCount(), 0)
        let counts = store.counts()
        XCTAssertEqual(counts.tabs, 1)
        XCTAssertEqual(counts.panes, 1)
        // The surviving workspace still restores.
        XCTAssertEqual(store.loadState(workspaceId: StateStore.defaultWorkspaceId)[0]
            .tabs[0].panes["dp"]?.cwd, "/tmp")
    }
}
