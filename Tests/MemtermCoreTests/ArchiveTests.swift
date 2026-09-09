import XCTest
import SQLite3
@testable import MemtermCore

// Schema v6 / founder-amended FR-56 (approved 2026-09-02): closing archives
// — scrollback + per-tab history move into the timeline archive (searchable,
// per-card forgettable) instead of dying. EXPLICIT Forget gestures remain
// TRUE deletion, archive included. These tests cover the migration fixture,
// the close→archive→query round-trip, the forget-scope matrix
// (pane/tab/workspace/everything × live/archived), freeze-before-trim,
// retention, orphan sweeps, and NFR-10 perms.

final class ArchiveTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!
    private var scrollbackDir: URL!
    private var historyDir: URL!
    private var archiveDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-archive-tests-\(UUID().uuidString)")
        scrollbackDir = tempDir.appendingPathComponent("scrollback")
        historyDir = tempDir.appendingPathComponent("history")
        archiveDir = tempDir.appendingPathComponent("archive")
        for dir in [scrollbackDir, historyDir, archiveDir] {
            try FileManager.default.createDirectory(at: dir!,
                                                    withIntermediateDirectories: true)
        }
        dbURL = tempDir.appendingPathComponent("state.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Same world as CloseForgetTests: Default holds one window (t1: split
    /// p1+p2, t2: single p3), workspace B holds t3 (single p4); scrollback
    /// and .hist files for every pane.
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
        ], color: "#ff9500")
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
        store.upsertSnapshot("p3", exe: "/usr/bin/tail", argv: ["tail", "-f", "x"], pid: 12,
                             adapter: "watcher", adapterState: ["file": "x"])
        store.setMeta("boot_session_uuid", "BOOT-UUID-TEST")
        store.barrier()
        for paneId in ["p1", "p2", "p3", "p4"] {
            try "scrollback \(paneId)".write(
                to: ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId),
                atomically: true, encoding: .utf8)
            try ": 1700000000:0;echo live-\(paneId)\n".write(
                to: ShellIntegration.histFileURL(dir: historyDir, paneId: paneId),
                atomically: true, encoding: .utf8)
        }
    }

    private func sessionDir(_ id: Int64) -> URL {
        StateStore.archiveSessionDir(archiveDir, id: id)
    }

    private func liveScrollbackExists(_ paneId: String) -> Bool {
        FileManager.default.fileExists(
            atPath: ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId).path)
    }

    // MARK: - Migration v5 → v6

    private func authorV5Fixture(at url: URL) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE workspaces (id TEXT PRIMARY KEY, name TEXT, color TEXT,
                                 ord INTEGER, is_parked INTEGER DEFAULT 0);
        CREATE TABLE windows (id TEXT PRIMARY KEY, frame TEXT, ord INTEGER,
                              focused_tab TEXT, workspace_id TEXT, updated_at INTEGER);
        CREATE TABLE tabs (id TEXT PRIMARY KEY, window_id TEXT, ord INTEGER,
                           title TEXT, split_tree TEXT, workspace_id TEXT,
                           updated_at INTEGER, color TEXT);
        CREATE TABLE panes (id TEXT PRIMARY KEY, tab_id TEXT, shell TEXT,
                            cwd TEXT, cwd_source TEXT, updated_at INTEGER);
        CREATE TABLE pane_snapshot (pane_id TEXT PRIMARY KEY, exe TEXT, argv TEXT,
                                    pid INTEGER, proc_start INTEGER, adapter TEXT,
                                    adapter_state TEXT, updated_at INTEGER);
        CREATE TABLE serial_profiles (identity TEXT PRIMARY KEY, settings TEXT,
                                      tx TEXT, local_echo INTEGER, last_path TEXT,
                                      label TEXT, updated_at INTEGER);
        INSERT INTO meta VALUES ('schema_version', '5');
        INSERT INTO workspaces VALUES ('default', 'Default', '#8e8e93', 0, 0);
        INSERT INTO windows VALUES ('w1', '0,0,900,600', 0, 't1', 'default', 1);
        INSERT INTO tabs VALUES ('t1', 'w1', 0, 'kept', '{"pane":"p1"}', 'default', 1, '#ff9500');
        INSERT INTO panes VALUES ('p1', 't1', '/bin/zsh', '/tmp', 'kernel', 1);
        INSERT INTO pane_snapshot VALUES ('p1', '/usr/bin/ssh', '["ssh","host"]',
                                          11, 99, 'ssh', '{}', 1);
        """, nil, nil, &err)
        if rc != SQLITE_OK {
            XCTFail("fixture SQL failed: \(err.map { String(cString: $0) } ?? "rc \(rc)")")
        }
        sqlite3_close(db)
    }

    /// A real v5 journal upgrades in place, losslessly and idempotently: v6
    /// only ADDS the sessions + FTS tables; every v5 row restores unchanged,
    /// and the fresh archive is empty but fully queryable.
    func testV5ToV6MigrationIsLosslessAndIdempotent() throws {
        authorV5Fixture(at: dbURL)

        var store: StateStore? = StateStore(url: dbURL)
        XCTAssertEqual(store!.getMeta("schema_version"), "7")
        XCTAssertEqual(store!.archivedSessionCount(), 0)
        XCTAssertTrue(store!.archivedSessions().isEmpty)
        XCTAssertTrue(store!.searchArchivedSessions("anything").isEmpty)
        var restored = store!.loadState()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].tabs[0].title, "kept")
        XCTAssertEqual(restored[0].tabs[0].color, "#ff9500")
        XCTAssertEqual(restored[0].tabs[0].panes["p1"]?.cwd, "/tmp")
        XCTAssertEqual(restored[0].tabs[0].panes["p1"]?.snapshot?.adapter, "ssh")

        // Idempotent: a second open (the next launch) re-runs the migration
        // over a v6 file and changes nothing.
        store = nil
        store = StateStore(url: dbURL)
        XCTAssertEqual(store!.getMeta("schema_version"), "7")
        restored = store!.loadState()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].tabs[0].panes["p1"]?.snapshot?.adapter, "ssh")
        XCTAssertEqual(store!.archivedSessionCount(), 0)
    }

    // MARK: - Close → archive → query round-trip

    func testCloseArchivesQueryRoundTrip() throws {
        let store = StateStore(url: dbURL)
        try populate(store)

        store.archiveTabs(["t2"], closeReason: .userClose,
                          scrollbackDir: scrollbackDir, historyDir: historyDir,
                          archiveDir: archiveDir, openedAt: ["p3": 1_700_000_100])
        store.barrier()

        // One sessions row, every column honest.
        let rows = store.archivedSessions()
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.paneId, "p3")
        XCTAssertEqual(row.tabId, "t2")
        XCTAssertEqual(row.workspaceId, StateStore.defaultWorkspaceId)
        XCTAssertEqual(row.workspaceName, "Default")
        XCTAssertEqual(row.workspaceColor, StateStore.defaultWorkspaceColor)
        XCTAssertEqual(row.openedAt, 1_700_000_100)
        XCTAssertGreaterThan(row.closedAt, 1_700_000_100)
        XCTAssertEqual(row.closeReason, SessionCloseReason.userClose.rawValue)
        XCTAssertEqual(row.cwdLast, "/opt")
        XCTAssertEqual(row.shell, "/bin/zsh")
        XCTAssertEqual(row.adapter, "watcher")
        XCTAssertEqual(row.adapterState, ["file": "x"])
        XCTAssertEqual(row.bootSessionUUID, "BOOT-UUID-TEST")
        XCTAssertEqual(row.customTitle, "two")
        XCTAssertEqual(row.tabColor, "#ff9500")
        XCTAssertEqual(row.preview, "echo live-p3")

        // Files MOVED (not copied): frozen in the session dir, gone live.
        let dir = sessionDir(row.id)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("scrollback.txt"),
                                  encoding: .utf8), "scrollback p3")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("history.hist"),
                                  encoding: .utf8), ": 1700000000:0;echo live-p3\n")
        XCTAssertFalse(liveScrollbackExists("p3"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ShellIntegration.histFileURL(dir: historyDir, paneId: "p3").path))

        // Live tables clean, everything else untouched.
        let restored = store.loadState(workspaceId: StateStore.defaultWorkspaceId)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].tabs.count, 1, "t2 must never restore")
        XCTAssertNil(restored[0].tabs[0].panes["p3"])
        XCTAssertEqual(store.snapshotCount(), 0, "p3's snapshot goes with it")
        XCTAssertEqual(store.loadState(workspaceId: "wsB").count, 1)
        XCTAssertTrue(liveScrollbackExists("p1"))

        // Kit surface round-trips: frozen scrollback + FTS search.
        XCTAssertEqual(store.archivedScrollbackText(id: row.id, archiveDir: archiveDir),
                       "scrollback p3")
        XCTAssertEqual(store.searchArchivedSessions("live-p3").map(\.id), [row.id])
        XCTAssertTrue(store.searchArchivedSessions("no-such-command").isEmpty)
        // Hostile FTS syntax never throws or matches everything.
        XCTAssertTrue(store.searchArchivedSessions("\"unbalanced OR *").isEmpty)
        XCTAssertNil(store.archivedScrollbackText(id: 424_242, archiveDir: archiveDir))
    }

    /// Closing a whole tab of several panes archives one session per pane;
    /// a shell dying on its own records the honest close_reason.
    func testMultiPaneTabAndShellExitedReason() throws {
        let store = StateStore(url: dbURL)
        try populate(store)

        store.archiveTabs(["t1"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                          historyDir: historyDir, archiveDir: archiveDir)
        store.archivePanes(["p4"], closeReason: .shellExited, scrollbackDir: scrollbackDir,
                           historyDir: historyDir, archiveDir: archiveDir)
        store.barrier()

        let rows = store.archivedSessions()
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(Set(rows.map(\.paneId)), ["p1", "p2", "p4"])
        let p4 = try XCTUnwrap(rows.first { $0.paneId == "p4" })
        XCTAssertEqual(p4.closeReason, SessionCloseReason.shellExited.rawValue)
        XCTAssertEqual(p4.workspaceName, "B")
        // t1's row is gone but its window survives (t2 still lives there);
        // wsB's tab row stays too (pane close ≠ tab close).
        let restored = store.loadState(workspaceId: StateStore.defaultWorkspaceId)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].tabs.map(\.title), ["two"])
        XCTAssertEqual(store.counts().tabs, 2)
    }

    /// A pane closed before its first capture (no live row) archives nothing
    /// and breaks nothing.
    func testArchivingUnknownPaneIsHarmless() throws {
        let store = StateStore(url: dbURL)
        try populate(store)
        store.archivePanes(["never-captured"], closeReason: .userClose,
                           scrollbackDir: scrollbackDir, historyDir: historyDir,
                           archiveDir: archiveDir)
        store.archiveTabs([], closeReason: .userClose, scrollbackDir: scrollbackDir,
                          historyDir: historyDir, archiveDir: archiveDir)
        store.barrier()
        XCTAssertEqual(store.archivedSessionCount(), 0)
        XCTAssertEqual(store.counts().panes, 4)
    }

    // MARK: - Forget-scope matrix (pane/tab/workspace/everything × live/archived)

    /// Archives t2 (Default) and p4 (wsB), then walks every explicit-forget
    /// scope: each deletes exactly its own archived slice — rows, FTS
    /// entries, and frozen files.
    func testForgetScopeMatrix() throws {
        var store: StateStore? = StateStore(url: dbURL)
        try populate(store!)
        store!.archiveTabs(["t2"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                           historyDir: historyDir, archiveDir: archiveDir)
        store!.archivePanes(["p4"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                            historyDir: historyDir, archiveDir: archiveDir)
        store!.barrier()
        let byPane = Dictionary(uniqueKeysWithValues:
            store!.archivedSessions().map { ($0.paneId, $0.id) })
        XCTAssertEqual(Set(byPane.keys), ["p3", "p4"])

        // Pane scope with NO archiveDir (a plain close-funnel cleanup, or an
        // engine without the amendment): archive untouched.
        store!.forgetPanes(["p3"], scrollbackDir: scrollbackDir, historyDir: historyDir)
        store!.barrier()
        XCTAssertEqual(store!.archivedSessionCount(), 2,
                       "forget without archive scope must keep archived rows")

        // Pane scope WITH archiveDir (FR-57 Forget Pane Memory): p3's
        // archived session dies — row, search hit, frozen dir.
        store!.forgetPanes(["p3"], scrollbackDir: scrollbackDir, historyDir: historyDir,
                           archiveDir: archiveDir)
        store!.barrier()
        XCTAssertEqual(store!.archivedSessions().map(\.paneId), ["p4"])
        XCTAssertTrue(store!.searchArchivedSessions("live-p3").isEmpty,
                      "FTS entry must die with the session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir(byPane["p3"]!).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir(byPane["p4"]!).path))

        // Tab scope (Forget Tab Memory) on the tab whose pane is archived.
        store!.forgetTabs(["t3"], scrollbackDir: scrollbackDir, historyDir: historyDir,
                          archiveDir: archiveDir)
        store!.barrier()
        XCTAssertEqual(store!.archivedSessionCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir(byPane["p4"]!).path))

        // Workspace scope: re-archive into wsB, then forget the workspace
        // explicitly — its archived slice dies; Default's survives.
        try populate(store!)
        store!.archiveTabs(["t2"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                           historyDir: historyDir, archiveDir: archiveDir)
        store!.archivePanes(["p4"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                            historyDir: historyDir, archiveDir: archiveDir)
        store!.forgetWorkspace("wsB", scrollbackDir: scrollbackDir, historyDir: historyDir,
                               archiveDir: archiveDir)
        store!.barrier()
        XCTAssertEqual(store!.archivedSessions().map(\.paneId), ["p3"],
                       "explicit workspace forget must delete its archived slice only")

        // The last-tab-close auto-remove analog: forgetWorkspace WITHOUT
        // archiveDir keeps the survivors' cards (denormalized name intact).
        store!.forgetWorkspace(StateStore.defaultWorkspaceId, scrollbackDir: scrollbackDir,
                               historyDir: historyDir)
        store!.barrier()
        XCTAssertEqual(store!.archivedSessions().map(\.paneId), ["p3"])
        XCTAssertEqual(store!.archivedSessions()[0].workspaceName, "Default",
                       "card keeps the dead workspace's denormalized name")

        // Everything: purgeAll leaves an EMPTY archive.
        store = nil
        StateStore.purgeAll(dbURL: dbURL, scrollbackDir: scrollbackDir,
                            historyDir: historyDir, archiveDir: archiveDir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: archiveDir.path),
                       [])
        let fresh = StateStore(url: dbURL)
        XCTAssertEqual(fresh.archivedSessionCount(), 0)
    }

    /// Per-card Forget (the timeline / kit requestForget path).
    func testPerCardForgetDeletesExactlyThatSession() throws {
        let store = StateStore(url: dbURL)
        try populate(store)
        store.archiveTabs(["t1"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                          historyDir: historyDir, archiveDir: archiveDir)
        store.barrier()
        let rows = store.archivedSessions()
        XCTAssertEqual(rows.count, 2)
        let doomed = rows[0], kept = rows[1]

        store.deleteArchivedSession(id: doomed.id, archiveDir: archiveDir)
        store.deleteArchivedSession(id: 999_999, archiveDir: archiveDir)  // harmless
        store.barrier()

        XCTAssertEqual(store.archivedSessions().map(\.id), [kept.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir(doomed.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir(kept.id).path))
    }

    // MARK: - Freeze-before-trim

    /// The council's data-loss finding: commands the 2000→1000 trim rolled
    /// into the sidecar must archive with the session — frozen file AND
    /// searchable.
    func testTrimSidecarArchivesWithTheSession() throws {
        let store = StateStore(url: dbURL)
        try populate(store)
        try ": 1600000000:0;make ancient-target\n".write(
            to: ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: "p3"),
            atomically: true, encoding: .utf8)

        store.archiveTabs(["t2"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                          historyDir: historyDir, archiveDir: archiveDir)
        store.barrier()

        let row = try XCTUnwrap(store.archivedSessions().first)
        let frozen = sessionDir(row.id).appendingPathComponent("history-trimmed.hist")
        XCTAssertEqual(try String(contentsOf: frozen, encoding: .utf8),
                       ": 1600000000:0;make ancient-target\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: "p3").path),
            "sidecar must MOVE, not copy")
        // Rolled-out commands search too, and sit before live ones.
        XCTAssertEqual(store.searchArchivedSessions("ancient-target").map(\.id), [row.id])
        XCTAssertEqual(store.searchArchivedSessions("live-p3").map(\.id), [row.id])
        XCTAssertEqual(row.preview, "echo live-p3", "preview is the LAST live command")
    }

    /// The pure trim mirror partitions losslessly.
    func testTrimHistoryPartitionsLosslessly() {
        let lines = (0..<2500).map { ": 1:0;cmd-\($0)" }
        let (kept, rolled) = ShellIntegration.trimHistory(lines: lines)
        XCTAssertEqual(kept.count, 1000)
        XCTAssertEqual(rolled.count, 1500)
        XCTAssertEqual(rolled.first, ": 1:0;cmd-0")
        XCTAssertEqual(rolled.last, ": 1:0;cmd-1499")
        XCTAssertEqual(kept.first, ": 1:0;cmd-1500")
        XCTAssertEqual(rolled + kept, lines, "roll + keep must lose nothing")
        let under = ShellIntegration.trimHistory(lines: ["a", "b"])
        XCTAssertEqual(under.kept, ["a", "b"])
        XCTAssertTrue(under.rolled.isEmpty)
    }

    // MARK: - Retention

    func testRetentionDeletesOnlyExpiredSessions() throws {
        let store = StateStore(url: dbURL)
        try populate(store)
        store.archiveTabs(["t2"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                          historyDir: historyDir, archiveDir: archiveDir)
        store.archivePanes(["p4"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                           historyDir: historyDir, archiveDir: archiveDir)
        store.barrier()
        let rows = store.archivedSessions()
        XCTAssertEqual(rows.count, 2)
        let old = try XCTUnwrap(rows.first { $0.paneId == "p3" })
        let young = try XCTUnwrap(rows.first { $0.paneId == "p4" })

        // Age p3's row via a second WAL connection (the store's own API is
        // append-only by design — no backdoor worth building for a test).
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        let ancient = Int(Date().timeIntervalSince1970) - 200 * 86_400
        XCTAssertEqual(sqlite3_exec(
            db, "UPDATE sessions SET closed_at = \(ancient) WHERE id = \(old.id)",
            nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        // 0 = keep forever.
        store.enforceArchiveRetention(maxAgeDays: 0, archiveDir: archiveDir)
        store.barrier()
        XCTAssertEqual(store.archivedSessionCount(), 2)

        store.enforceArchiveRetention(maxAgeDays: 90, archiveDir: archiveDir)
        store.barrier()
        XCTAssertEqual(store.archivedSessions().map(\.id), [young.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir(old.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir(young.id).path))
        XCTAssertTrue(store.searchArchivedSessions("live-p3").isEmpty)
    }

    // MARK: - Orphan sweep + NFR-10 perms

    func testOrphanSweepCollectsRowlessArchiveDirsAndTrimSidecars() throws {
        let store = StateStore(url: dbURL)
        try populate(store)
        store.archiveTabs(["t2"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                          historyDir: historyDir, archiveDir: archiveDir)
        store.barrier()
        let kept = try XCTUnwrap(store.archivedSessions().first)

        // A rowless archive dir (torn per-card forget) and an orphan sidecar.
        let stray = archiveDir.appendingPathComponent("424242")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "stray".write(to: stray.appendingPathComponent("scrollback.txt"),
                          atomically: true, encoding: .utf8)
        try "old".write(
            to: ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: "gone-pane"),
            atomically: true, encoding: .utf8)
        try "live".write(
            to: ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: "p1"),
            atomically: true, encoding: .utf8)

        store.purgeOrphanScrollback(dir: scrollbackDir, historyDir: historyDir,
                                    archiveDir: archiveDir)
        store.barrier()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir(kept.id).path),
                      "a session WITH a row must survive the sweep")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ShellIntegration.histTrimSidecarURL(dir: historyDir,
                                                        paneId: "gone-pane").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: "p1").path))
    }

    /// Torn archive move (adversarial gate, train part 2): performArchive
    /// COMMITs the sessions row + live-row deletes FIRST and moves the frozen
    /// files after — a kill -9 in between leaves the pane's scrollback/.hist
    /// in the LIVE dirs with no pane row. The next launch's sweep must HEAL
    /// that state (complete the move into <archive>/<rowid>/), never delete
    /// the bytes the sessions row promises.
    func testSweepHealsTornArchiveMoveInsteadOfDeleting() throws {
        let store = StateStore(url: dbURL)
        try populate(store)
        try ": 1600000000:0;make torn-sidecar\n".write(
            to: ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: "p3"),
            atomically: true, encoding: .utf8)
        store.archiveTabs(["t2"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                          historyDir: historyDir, archiveDir: archiveDir)
        store.barrier()
        let row = try XCTUnwrap(store.archivedSessions().first)
        let dir = sessionDir(row.id)
        let fm = FileManager.default

        // Simulate the kill -9 window: files back in the live dirs, the
        // archive session dir never created.
        try fm.moveItem(at: dir.appendingPathComponent("scrollback.txt"),
                        to: ScrollbackText.fileURL(dir: scrollbackDir, paneId: "p3"))
        try fm.moveItem(at: dir.appendingPathComponent("history.hist"),
                        to: ShellIntegration.histFileURL(dir: historyDir, paneId: "p3"))
        try fm.moveItem(at: dir.appendingPathComponent("history-trimmed.hist"),
                        to: ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: "p3"))
        try fm.removeItem(at: dir)

        // The launch-time sweep must complete the move, not delete the strays.
        store.purgeOrphanScrollback(dir: scrollbackDir, historyDir: historyDir,
                                    archiveDir: archiveDir)
        store.barrier()

        XCTAssertEqual(store.archivedScrollbackText(id: row.id, archiveDir: archiveDir),
                       "scrollback p3",
                       "healed archive must serve the frozen scrollback")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("history.hist"),
                                  encoding: .utf8),
                       ": 1700000000:0;echo live-p3\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("history-trimmed.hist"),
                                  encoding: .utf8),
                       ": 1600000000:0;make torn-sidecar\n")
        XCTAssertFalse(liveScrollbackExists("p3"), "heal must MOVE, not copy")
        XCTAssertFalse(fm.fileExists(
            atPath: ShellIntegration.histFileURL(dir: historyDir, paneId: "p3").path))
        // NFR-10 holds on the healed files too.
        let dirPerms = try XCTUnwrap(
            try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int)
        XCTAssertEqual(dirPerms & 0o777, 0o700)
        let filePerms = try XCTUnwrap(try fm.attributesOfItem(
            atPath: dir.appendingPathComponent("scrollback.txt").path)[.posixPermissions] as? Int)
        XCTAssertEqual(filePerms & 0o777, 0o600)
        // A healed session must not be double-collected by a second sweep.
        store.purgeOrphanScrollback(dir: scrollbackDir, historyDir: historyDir,
                                    archiveDir: archiveDir)
        store.barrier()
        XCTAssertNotNil(store.archivedScrollbackText(id: row.id, archiveDir: archiveDir))
    }

    /// NFR-10 extends to the archive: 0700 session dirs, 0600 frozen files.
    func testArchivePermissions() throws {
        let store = StateStore(url: dbURL)
        try populate(store)
        store.archiveTabs(["t2"], closeReason: .userClose, scrollbackDir: scrollbackDir,
                          historyDir: historyDir, archiveDir: archiveDir)
        store.barrier()
        let row = try XCTUnwrap(store.archivedSessions().first)
        let dir = sessionDir(row.id)
        let fm = FileManager.default
        let dirPerms = try XCTUnwrap(
            try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int)
        XCTAssertEqual(dirPerms & 0o777, 0o700)
        for name in ["scrollback.txt", "history.hist"] {
            let perms = try XCTUnwrap(try fm.attributesOfItem(
                atPath: dir.appendingPathComponent(name).path)[.posixPermissions] as? Int)
            XCTAssertEqual(perms & 0o777, 0o600, "\(name) must be 0600")
        }
    }
}
