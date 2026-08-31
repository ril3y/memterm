import XCTest
import SQLite3
@testable import MemtermCore

// Custom-tab-chrome stage 2 gate: THE state.db on the founder's machine —
// written by the pre-migration (native-NSWindow-tabbing) build — must restore
// perfectly. The rearchitecture deliberately changed no journal identifiers
// (tabId, paneId, windows/tabs/panes rows), so these fixtures author the
// exact schemas older builds wrote, byte-for-byte independent of the current
// writer code, and assert the current StateStore loads every row intact.
final class PreMigrationRestoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-premigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func authorFixture(at url: URL, sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            XCTFail("fixture SQL failed: \(err.map { String(cString: $0) } ?? "rc \(rc)")")
        }
        sqlite3_close(db)
    }

    /// The pre-custom-tabs build's schema (v5: workspaces, workspace_id,
    /// proc_start, tab color, serial_profiles) with a realistic layout:
    /// Default holds one window of two tabs — a colored single-pane tab and a
    /// custom-titled split tab — and a parked Infra workspace holds a serial
    /// pane's reconnectable snapshot.
    func testNativeTabEraStateRestoresIntact() {
        let url = dir.appendingPathComponent("state.db")
        authorFixture(at: url, sql: """
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
        INSERT INTO meta VALUES ('active_workspace_id', 'default');
        INSERT INTO workspaces VALUES ('default', 'Default', '#8e8e93', 0, 0);
        INSERT INTO workspaces VALUES ('ws-infra', 'Infra', '#0a84ff', 1, 1);
        INSERT INTO windows VALUES ('tab-a', '100,120,980,640', 0, 'tab-b', 'default', 1000);
        INSERT INTO windows VALUES ('tab-c', '60,80,800,600', 0, 'tab-c', 'ws-infra', 1000);
        INSERT INTO tabs VALUES ('tab-a', 'tab-a', 0, '', '{"pane":"pane-1"}',
                                 'default', 1000, '#febc2e');
        INSERT INTO tabs VALUES ('tab-b', 'tab-a', 1, 'builds',
            '{"vertical":true,"ratio":0.4,"children":[{"pane":"pane-2"},{"pane":"pane-3"}]}',
            'default', 1000, NULL);
        INSERT INTO tabs VALUES ('tab-c', 'tab-c', 0, '', '{"pane":"pane-4"}',
                                 'ws-infra', 1000, NULL);
        INSERT INTO panes VALUES ('pane-1', 'tab-a', '/bin/zsh', '/tmp', 'kernel', 1000);
        INSERT INTO panes VALUES ('pane-2', 'tab-b', '/bin/zsh', '/Users/f/proj', 'kernel', 1000);
        INSERT INTO panes VALUES ('pane-3', 'tab-b', NULL, NULL, NULL, 1000);
        INSERT INTO panes VALUES ('pane-4', 'tab-c', NULL, NULL, NULL, 1000);
        INSERT INTO pane_snapshot VALUES ('pane-1', '/usr/local/bin/claude',
            '["claude"]', 4242, 777, 'claude', '{"sessionId":"11111111-2222-3333-4444-555555555555"}', 1000);
        INSERT INTO pane_snapshot VALUES ('pane-4', '', '[]', 0, 0, 'serial',
            '{"path":"/dev/cu.usbserial-0001","identity":"usb:303a:1001:88","label":"esp32","settings":"115200-8N1","tx":"crlf","echo":"0"}', 1000);
        INSERT INTO serial_profiles VALUES ('usb:303a:1001:88', '115200-8N1', 'crlf',
                                            0, '/dev/cu.usbserial-0001', 'esp32', 1000);
        """)

        for pass in 1...2 {  // second open proves the migration is idempotent
            let store = StateStore(url: url)

            let workspaces = store.listWorkspaces()
            XCTAssertEqual(workspaces.count, 2, "pass \(pass)")
            XCTAssertEqual(workspaces[0],
                           WorkspaceRow(id: "default", name: "Default", color: "#8e8e93",
                                        ord: 0, isParked: false))
            XCTAssertEqual(workspaces[1],
                           WorkspaceRow(id: "ws-infra", name: "Infra", color: "#0a84ff",
                                        ord: 1, isParked: true))
            XCTAssertEqual(store.getMeta("active_workspace_id"), "default")

            // Default workspace: 1 window, frame + focused tab + tab order,
            // colors, titles, trees, pane identities, cwds, snapshots — all
            // byte-identical to what the old build journaled.
            let defaults = store.loadState(workspaceId: "default")
            XCTAssertEqual(defaults.count, 1)
            let win = defaults[0]
            XCTAssertEqual(win.frame, "100,120,980,640")
            XCTAssertEqual(win.focusedTab, "tab-b")
            XCTAssertEqual(win.tabs.count, 2)
            XCTAssertEqual(win.tabs[0].tree, .pane("pane-1"))
            XCTAssertEqual(win.tabs[0].title, "")
            XCTAssertEqual(win.tabs[0].color, "#febc2e")
            XCTAssertEqual(win.tabs[0].panes["pane-1"]?.cwd, "/tmp")
            XCTAssertEqual(win.tabs[0].panes["pane-1"]?.shell, "/bin/zsh")
            XCTAssertEqual(win.tabs[0].panes["pane-1"]?.snapshot?.adapter, "claude")
            XCTAssertEqual(win.tabs[0].panes["pane-1"]?.snapshot?.adapterState["sessionId"],
                           "11111111-2222-3333-4444-555555555555")
            XCTAssertEqual(win.tabs[1].title, "builds")
            XCTAssertNil(win.tabs[1].color)
            XCTAssertEqual(win.tabs[1].tree,
                           .split(vertical: true, ratio: 0.4,
                                  first: .pane("pane-2"), second: .pane("pane-3")))
            XCTAssertEqual(win.tabs[1].panes["pane-2"]?.cwd, "/Users/f/proj")
            XCTAssertNil(win.tabs[1].panes["pane-3"]?.cwd)

            // Parked Infra workspace: rows intact, serial snapshot offer-ready.
            let infra = store.loadState(workspaceId: "ws-infra")
            XCTAssertEqual(infra.count, 1)
            XCTAssertEqual(infra[0].frame, "60,80,800,600")
            XCTAssertEqual(infra[0].tabs.count, 1)
            let serial = infra[0].tabs[0].panes["pane-4"]?.snapshot
            XCTAssertEqual(serial?.adapter, "serial")
            XCTAssertEqual(serial?.adapterState["path"], "/dev/cu.usbserial-0001")
            XCTAssertEqual(serial?.adapterState["settings"], "115200-8N1")

            // The serial profile the connect sheet pre-fills from.
            let profile = store.serialProfile(identity: "usb:303a:1001:88")
            XCTAssertEqual(profile?.settings, "115200-8N1")
            XCTAssertEqual(profile?.lastPath, "/dev/cu.usbserial-0001")

            // Full (unscoped) load sees both windows, ordered.
            XCTAssertEqual(store.loadState().count, 2)
            let counts = store.counts()
            XCTAssertEqual(counts.windows, 2)
            XCTAssertEqual(counts.tabs, 3)
            XCTAssertEqual(counts.panes, 4)
            store.barrier()
        }
    }

    /// The oldest journal shape (v1: no workspaces table, no workspace_id /
    /// proc_start / color columns): opening it must create Default, adopt the
    /// orphan rows into it, and restore the layout — never drop anything.
    func testV1SchemaMigratesAndRestores() {
        let url = dir.appendingPathComponent("state.db")
        authorFixture(at: url, sql: """
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
        INSERT INTO windows VALUES ('tab-old', '10,20,900,500', 0, 'tab-old', 999);
        INSERT INTO tabs VALUES ('tab-old', 'tab-old', 0, 'legacy', '{"pane":"pane-old"}', 999);
        INSERT INTO panes VALUES ('pane-old', 'tab-old', '/bin/bash', '/var/log', 'kernel', 999);
        INSERT INTO pane_snapshot VALUES ('pane-old', '/usr/bin/ssh',
            '["ssh","host"]', 77, 'ssh', '{"argv":"ssh host"}', 999);
        """)

        let store = StateStore(url: url)
        let workspaces = store.listWorkspaces()
        XCTAssertEqual(workspaces.count, 1)
        XCTAssertEqual(workspaces[0].id, StateStore.defaultWorkspaceId)
        XCTAssertFalse(workspaces[0].isParked)

        // The orphan rows were adopted by Default — a workspace-scoped load
        // (the launch path) finds them there.
        let restored = store.loadState(workspaceId: StateStore.defaultWorkspaceId)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].frame, "10,20,900,500")
        XCTAssertEqual(restored[0].focusedTab, "tab-old")
        XCTAssertEqual(restored[0].tabs.count, 1)
        XCTAssertEqual(restored[0].tabs[0].title, "legacy")
        XCTAssertNil(restored[0].tabs[0].color)
        XCTAssertEqual(restored[0].tabs[0].tree, .pane("pane-old"))
        XCTAssertEqual(restored[0].tabs[0].panes["pane-old"]?.cwd, "/var/log")
        XCTAssertEqual(restored[0].tabs[0].panes["pane-old"]?.shell, "/bin/bash")
        XCTAssertEqual(restored[0].tabs[0].panes["pane-old"]?.snapshot?.adapter, "ssh")
        store.barrier()
    }
}
