import Foundation
import SQLite3

// FR-12/17: the durable description of the workspace. SQLite WAL (default
// location: ~/Library/Application Support/memterm/state.db — the base
// directory is injectable so tests run in temp dirs), one serial queue as the
// single writer, whole-topology transactional rewrites (the topology is tiny;
// rewriting it beats diffing it for correctness).

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Model

public indirect enum SplitNode: Equatable {
    case pane(String)
    case split(vertical: Bool, ratio: Double, first: SplitNode, second: SplitNode)

    public var paneIds: [String] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, _, let a, let b): return a.paneIds + b.paneIds
        }
    }

    public func toJSONObject() -> Any {
        switch self {
        case .pane(let id):
            return ["pane": id]
        case .split(let vertical, let ratio, let a, let b):
            return ["vertical": vertical, "ratio": ratio,
                    "children": [a.toJSONObject(), b.toJSONObject()]]
        }
    }

    public static func from(jsonObject: Any) -> SplitNode? {
        guard let dict = jsonObject as? [String: Any] else { return nil }
        if let id = dict["pane"] as? String { return .pane(id) }
        guard let vertical = dict["vertical"] as? Bool,
              let ratio = dict["ratio"] as? Double,
              let children = dict["children"] as? [Any], children.count == 2,
              let a = from(jsonObject: children[0]),
              let b = from(jsonObject: children[1]) else { return nil }
        return .split(vertical: vertical, ratio: ratio, first: a, second: b)
    }
}

// FR-49: workspace entity — a named, colored group of tabs. `isParked` means
// closed-but-kept: the journal rows stay, the windows don't restore on launch.
// A non-parked workspace is "open" whether or not it is on screen right now.
public struct WorkspaceRow: Equatable {
    public var id: String
    public var name: String
    public var color: String  // "#rrggbb"
    public var ord: Int
    public var isParked: Bool

    public init(id: String, name: String, color: String, ord: Int, isParked: Bool) {
        self.id = id
        self.name = name
        self.color = color
        self.ord = ord
        self.isParked = isParked
    }
}

public struct PaneSnap {
    public var id: String
    public var shell: String?
    public var cwd: String?
    public var cwdSource: String?

    public init(id: String, shell: String?, cwd: String?, cwdSource: String?) {
        self.id = id
        self.shell = shell
        self.cwd = cwd
        self.cwdSource = cwdSource
    }
}

public struct TabSnap {
    public var id: String
    public var title: String
    public var tree: SplitNode
    public var panes: [PaneSnap]
    /// Founder 2026-08-31: user-set tab color (hex like "#0a84ff"), nil = none.
    public var color: String?

    public init(id: String, title: String, tree: SplitNode, panes: [PaneSnap],
                color: String? = nil) {
        self.id = id
        self.title = title
        self.tree = tree
        self.panes = panes
        self.color = color
    }
}

public struct WindowSnap {
    public var id: String
    public var frame: String  // "x,y,w,h"
    public var focusedTab: String?
    public var tabs: [TabSnap]
    /// FR-49: every tab belongs to exactly one workspace; a window (tab
    /// group) is homogeneous, so the workspace hangs off the window snap.
    public var workspaceId: String

    public init(id: String, frame: String, focusedTab: String?, tabs: [TabSnap],
                workspaceId: String = StateStore.defaultWorkspaceId) {
        self.id = id
        self.frame = frame
        self.focusedTab = focusedTab
        self.tabs = tabs
        self.workspaceId = workspaceId
    }
}

public struct SnapshotRow {
    public var exe: String
    public var argv: [String]
    public var adapter: String
    public var adapterState: [String: String]

    public init(exe: String, argv: [String], adapter: String, adapterState: [String: String]) {
        self.exe = exe
        self.argv = argv
        self.adapter = adapter
        self.adapterState = adapterState
    }
}

public struct PaneRestore {
    public var cwd: String?
    public var shell: String?
    public var snapshot: SnapshotRow?

    public init(cwd: String?, shell: String?, snapshot: SnapshotRow?) {
        self.cwd = cwd
        self.shell = shell
        self.snapshot = snapshot
    }
}

public struct TabRestore {
    public var title: String
    public var tree: SplitNode
    public var panes: [String: PaneRestore]
    public var color: String?

    public init(title: String, tree: SplitNode, panes: [String: PaneRestore],
                color: String? = nil) {
        self.title = title
        self.tree = tree
        self.panes = panes
        self.color = color
    }
}

/// Per-device serial line settings (feature/serial UX): remembered at connect
/// time keyed by the port's stable identity, so replugging the same board
/// pre-fills the sheet with what worked last time.
public struct SerialProfileRow: Equatable {
    public var identity: String
    public var settings: String       // SerialSettings.compactString
    public var txLineEnding: String   // SerialLineEnding.rawValue
    public var localEcho: Bool
    public var lastPath: String
    public var label: String

    public init(identity: String, settings: String, txLineEnding: String,
                localEcho: Bool, lastPath: String, label: String) {
        self.identity = identity
        self.settings = settings
        self.txLineEnding = txLineEnding
        self.localEcho = localEcho
        self.lastPath = lastPath
        self.label = label
    }
}

public struct WindowRestore {
    public var frame: String?
    public var focusedTab: String?
    public var tabs: [TabRestore]

    public init(frame: String?, focusedTab: String?, tabs: [TabRestore]) {
        self.frame = frame
        self.focusedTab = focusedTab
        self.tabs = tabs
    }
}

// MARK: - Archive (schema v6, founder-amended FR-56 2026-09-02)

/// Why a session left the live journal. Enumerates the REAL close funnel:
/// every user gesture (strip ✕, ⌘W, context-menu Close, close-pane, the
/// traffic-light close, and the last-tab close that auto-removes a
/// workspace) is `userClose`; a shell dying on its own (processTerminated,
/// `exit` typed included) is `shellExited`. Quit / switch / park teardown
/// never archives — those keep live rows exactly as before — and explicit
/// Forget gestures never archive either: they are TRUE deletion.
public enum SessionCloseReason: String {
    case userClose = "user-close"
    case shellExited = "shell-exited"
}

/// One archived session: a pane's frozen identity at the moment it was
/// closed. Append-only; workspace name/color are denormalized so the card
/// stays meaningful after the live workspace row is gone (e.g. the
/// last-tab-close auto-remove).
public struct ArchivedSessionRow: Equatable {
    public var id: Int64
    public var paneId: String
    public var tabId: String
    public var workspaceId: String
    public var workspaceName: String
    public var workspaceColor: String
    public var openedAt: Int?
    public var closedAt: Int
    public var closeReason: String
    public var cwdLast: String?
    public var shell: String?
    public var adapter: String?
    public var adapterState: [String: String]
    public var bootSessionUUID: String?
    public var customTitle: String?
    public var tabColor: String?
    public var preview: String
}

// MARK: - Store

public final class StateStore {
    private var db: OpaquePointer?
    private let writer = DispatchQueue(label: "memterm.state-store")
    /// listWorkspaces() cache: menu validation calls it on every key-equivalent
    /// dispatch, and an uncached read would writer.sync behind queued scrollback
    /// file writes. Invalidated by every workspace mutation.
    private let cacheLock = NSLock()
    private var workspaceCache: [WorkspaceRow]?

    /// Stable id of the auto-created workspace (FR-49): single-context users
    /// never see the concept until they want it.
    public static let defaultWorkspaceId = "default"
    public static let defaultWorkspaceColor = "#8e8e93"
    /// Generation backups kept next to state.db (FR-17): state.db.gen-1..gen-N,
    /// rotated on each successful open, tried newest-first on a corrupt open.
    public static let generationCount = 3

    public init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // FR-17: open + integrity-check; on failure, restore from the newest
        // passing generation; only with no usable generation degrade to empty.
        if !openAndVerify(url) {
            recoverFromGenerations(url)
        }
        guard db != nil else {
            NSLog("memterm: state store could not be opened or recovered at %@ — journaling disabled for this session", url.path)
            return
        }
        // The journal holds cwds, argv, and scrollback references: keep it
        // out of other local users' reach (NFR-10) — the directory is 0700,
        // the db itself 0600.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
        // Rotate the pre-launch file to gen-1 BEFORE this session writes, so a
        // torn write mid-session can always fall back to last launch's state.
        rotateGenerations(url)
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS workspaces (id TEXT PRIMARY KEY, name TEXT, color TEXT,
                                               ord INTEGER, is_parked INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS windows (id TEXT PRIMARY KEY, frame TEXT, ord INTEGER,
                                            focused_tab TEXT, workspace_id TEXT,
                                            updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS tabs (id TEXT PRIMARY KEY, window_id TEXT, ord INTEGER,
                                         title TEXT, split_tree TEXT, workspace_id TEXT,
                                         updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS panes (id TEXT PRIMARY KEY, tab_id TEXT, shell TEXT,
                                          cwd TEXT, cwd_source TEXT, updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS pane_snapshot (pane_id TEXT PRIMARY KEY, exe TEXT,
                                                  argv TEXT, pid INTEGER, proc_start INTEGER,
                                                  adapter TEXT, adapter_state TEXT,
                                                  updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS serial_profiles (identity TEXT PRIMARY KEY,
                                                    settings TEXT, tx TEXT,
                                                    local_echo INTEGER,
                                                    last_path TEXT, label TEXT,
                                                    updated_at INTEGER);
        """)
        migrateSchema()
    }

    /// Opens `url` and runs PRAGMA quick_check; on any failure the connection
    /// is closed and db stays nil. A 2 s busy timeout keeps a second
    /// connection's write lock from silently failing statements (SQLITE_BUSY
    /// used to be swallowed, degrading transactions to autocommit soup).
    private func openAndVerify(_ url: URL) -> Bool {
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, db != nil else {
            closeDB()
            return false
        }
        sqlite3_busy_timeout(db, 2000)
        var ok = false
        query("PRAGMA quick_check", []) { stmt in
            if column(stmt, 0) == "ok" { ok = true }
        }
        if !ok { closeDB() }
        return ok
    }

    private func closeDB() {
        if db != nil { sqlite3_close(db) }
        db = nil
    }

    private static func generationURL(_ url: URL, _ n: Int) -> URL {
        URL(fileURLWithPath: url.path + ".gen-\(n)")
    }

    /// Restore-from-last-known-good (FR-17): the corrupt file is moved aside
    /// and generations are tried newest-first; each candidate must itself pass
    /// quick_check before being adopted.
    private func recoverFromGenerations(_ url: URL) {
        let fm = FileManager.default
        let corrupt = URL(fileURLWithPath: url.path + ".corrupt")
        try? fm.removeItem(at: corrupt)
        try? fm.moveItem(at: url, to: corrupt)
        for sidecar in ["-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: url.path + sidecar))
        }
        for n in 1...Self.generationCount {
            let gen = Self.generationURL(url, n)
            guard fm.fileExists(atPath: gen.path) else { continue }
            try? fm.removeItem(at: url)
            guard (try? fm.copyItem(at: gen, to: url)) != nil else { continue }
            if openAndVerify(url) {
                NSLog("memterm: state.db was corrupt — restored from generation %d", n)
                return
            }
        }
        try? fm.removeItem(at: url)
        _ = openAndVerify(url)  // fresh empty store (still better than no store)
        if db != nil {
            NSLog("memterm: state.db was corrupt and no generation was usable — starting empty")
        }
    }

    /// On each successful open, the pre-launch file becomes gen-1 (older
    /// generations shift down, keep `generationCount`). WAL contents are
    /// checkpointed into the main file first so the copy is self-contained.
    private func rotateGenerations(_ url: URL) {
        exec("PRAGMA wal_checkpoint(TRUNCATE)")
        let fm = FileManager.default
        try? fm.removeItem(at: Self.generationURL(url, Self.generationCount))
        for n in stride(from: Self.generationCount - 1, through: 1, by: -1) {
            let from = Self.generationURL(url, n)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.moveItem(at: from, to: Self.generationURL(url, n + 1))
        }
        let gen1 = Self.generationURL(url, 1)
        try? fm.copyItem(at: url, to: gen1)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: gen1.path)
    }

    /// v1 → v2 (Group G): tabs/windows gain workspace_id, a "Default" workspace
    /// is auto-created, and existing rows are adopted into it in place —
    /// existing users' state must survive the upgrade. Idempotent; on a
    /// degraded (corrupt) open every statement no-ops.
    private func migrateSchema() {
        if !columnExists("tabs", "workspace_id") {
            exec("ALTER TABLE tabs ADD COLUMN workspace_id TEXT")
        }
        if !columnExists("windows", "workspace_id") {
            exec("ALTER TABLE windows ADD COLUMN workspace_id TEXT")
        }
        // v2 → v3: pane_snapshot gains proc_start (FR-14 PID-reuse guard).
        if !columnExists("pane_snapshot", "proc_start") {
            exec("ALTER TABLE pane_snapshot ADD COLUMN proc_start INTEGER")
        }
        // v3 → v4: tabs gain a user-set color (founder: right-click tab colors).
        if !columnExists("tabs", "color") {
            exec("ALTER TABLE tabs ADD COLUMN color TEXT")
        }
        run("""
            INSERT INTO workspaces (id, name, color, ord, is_parked)
            SELECT ?, 'Default', ?, 0, 0
            WHERE NOT EXISTS (SELECT 1 FROM workspaces)
            """, [.text(Self.defaultWorkspaceId), .text(Self.defaultWorkspaceColor)])
        // Orphan tabs/windows (pre-workspace rows, or rows whose workspace was
        // lost) are adopted by the first workspace, never dropped.
        var adopter: String?
        query("SELECT id FROM workspaces ORDER BY ord LIMIT 1", []) { stmt in
            adopter = column(stmt, 0)
        }
        if let adopter {
            for table in ["tabs", "windows"] {
                run("""
                    UPDATE \(table) SET workspace_id = ?
                    WHERE workspace_id IS NULL
                       OR workspace_id NOT IN (SELECT id FROM workspaces)
                    """, [.text(adopter)])
            }
        }
        // v4 → v5: serial_profiles (feature/serial UX — per-device remembered
        // line settings, keyed by the port's stable identity). New table only,
        // created in the init exec above; nothing to migrate in place.
        //
        // v5 → v6 (founder-amended FR-56, approved 2026-09-02): the archive.
        // Closing a tab ARCHIVES its scrollback + per-tab history instead of
        // deleting bytes. `sessions` is the append-only archive journal (one
        // row per closed pane), `session_fts` an FTS5 index over the pane's
        // command text (from its .hist file; scrollback is deliberately NOT
        // indexed — commands are the search key, scrollback stays a frozen
        // file read on demand). In-place, idempotent, lossless: no existing
        // v5 row is touched. There is deliberately no
        // "workspace-forgotten-survivor" close_reason: the last-tab-close
        // workspace auto-remove is a user close (the tab archived as
        // user-close before the empty workspace's live row goes), and an
        // EXPLICIT Forget Workspace deletes its archive scope outright.
        exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            id INTEGER PRIMARY KEY,
            pane_id TEXT, tab_id TEXT, workspace_id TEXT,
            workspace_name TEXT, workspace_color TEXT,
            opened_at INTEGER, closed_at INTEGER,
            close_reason TEXT,
            cwd_last TEXT, shell TEXT,
            adapter TEXT, adapter_state TEXT,
            boot_session_uuid TEXT,
            custom_title TEXT, tab_color TEXT,
            preview TEXT);
        """)
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(session_id UNINDEXED, commands)")
        run("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '6')")
    }

    private func columnExists(_ table: String, _ name: String) -> Bool {
        var found = false
        query("PRAGMA table_info(\(table))", []) { stmt in
            if column(stmt, 1) == name { found = true }
        }
        return found
    }

    deinit {
        sqlite3_close(db)
    }

    private func invalidateWorkspaceCache() {
        cacheLock.lock()
        workspaceCache = nil
        cacheLock.unlock()
    }

    // MARK: Meta

    public func setMeta(_ key: String, _ value: String) {
        writer.async { [self] in
            run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        }
    }

    public func getMeta(_ key: String) -> String? {
        writer.sync {
            var result: String?
            query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { stmt in
                result = column(stmt, 0)
            }
            return result
        }
    }

    // MARK: Workspaces (FR-49/50/51)

    public func listWorkspaces() -> [WorkspaceRow] {
        cacheLock.lock()
        if let cached = workspaceCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let rows: [WorkspaceRow] = writer.sync {
            var rows: [WorkspaceRow] = []
            query("SELECT id, name, color, ord, is_parked FROM workspaces ORDER BY ord", []) { stmt in
                guard let id = column(stmt, 0) else { return }
                rows.append(WorkspaceRow(id: id,
                                         name: column(stmt, 1) ?? "",
                                         color: column(stmt, 2) ?? Self.defaultWorkspaceColor,
                                         ord: Int(sqlite3_column_int64(stmt, 3)),
                                         isParked: sqlite3_column_int64(stmt, 4) != 0))
            }
            return rows
        }
        cacheLock.lock()
        workspaceCache = rows
        cacheLock.unlock()
        return rows
    }

    /// Appends the workspace at the end of the switcher order. Returns the id.
    @discardableResult
    public func createWorkspace(id: String = UUID().uuidString, name: String,
                                color: String) -> String {
        writer.async { [self] in
            run("""
                INSERT OR REPLACE INTO workspaces (id, name, color, ord, is_parked)
                VALUES (?,?,?,(SELECT COALESCE(MAX(ord) + 1, 0) FROM workspaces),0)
                """, [.text(id), .text(name), .text(color)])
        }
        invalidateWorkspaceCache()
        return id
    }

    public func renameWorkspace(_ id: String, name: String) {
        writer.async { [self] in
            run("UPDATE workspaces SET name = ? WHERE id = ?", [.text(name), .text(id)])
        }
        invalidateWorkspaceCache()
    }

    public func recolorWorkspace(_ id: String, color: String) {
        writer.async { [self] in
            run("UPDATE workspaces SET color = ? WHERE id = ?", [.text(color), .text(id)])
        }
        invalidateWorkspaceCache()
    }

    /// Parked = closed-but-kept (FR-51): rows stay, launch restore skips it.
    public func setWorkspaceParked(_ id: String, parked: Bool) {
        writer.async { [self] in
            run("UPDATE workspaces SET is_parked = ? WHERE id = ?",
                [.int(parked ? 1 : 0), .text(id)])
        }
        invalidateWorkspaceCache()
    }

    /// Removes one pane's on-disk byte trail: its scrollback file and (FR-56/57
    /// for the per-tab shell history) its .hist file plus the freeze-before-trim
    /// sidecar. All live under the state dir and all die with the same forget
    /// gestures.
    private static func removePaneFiles(_ paneId: String, scrollbackDir: URL?,
                                        historyDir: URL?) {
        if let scrollbackDir {
            try? FileManager.default.removeItem(
                at: ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId))
        }
        if let historyDir {
            try? FileManager.default.removeItem(
                at: ShellIntegration.histFileURL(dir: historyDir, paneId: paneId))
            try? FileManager.default.removeItem(
                at: ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: paneId))
        }
    }

    /// FR-50/57 "forget": purges the workspace's journal rows AND its panes'
    /// scrollback + shell-history files on disk — forgetting deletes bytes,
    /// not just the index. Files are removed only after the row purge COMMITs,
    /// so a failed transaction never leaves rows pointing at deleted files.
    /// `archiveDir` non-nil = the founder-amended FR-56 EXPLICIT-forget scope:
    /// the workspace's ARCHIVED sessions (rows, FTS entries, frozen files)
    /// die with its live rows. nil keeps the archive — the last-tab-close
    /// auto-remove path, where the just-archived tab is the survivor the
    /// archive exists for.
    public func forgetWorkspace(_ id: String, scrollbackDir: URL?, historyDir: URL? = nil,
                                archiveDir: URL? = nil) {
        writer.async { [self] in
            var paneIds: [String] = []
            if scrollbackDir != nil || historyDir != nil {
                query("""
                      SELECT p.id FROM panes p JOIN tabs t ON p.tab_id = t.id
                      WHERE t.workspace_id = ?
                      """, [.text(id)]) { stmt in
                    if let paneId = column(stmt, 0) { paneIds.append(paneId) }
                }
            }
            if let archiveDir {
                deleteArchivedRows(whereSQL: "workspace_id = ?", binds: [.text(id)],
                                   archiveDir: archiveDir)
            }
            let committed = inTransaction {
                var ok = true
                ok = run("""
                    DELETE FROM pane_snapshot WHERE pane_id IN
                      (SELECT p.id FROM panes p JOIN tabs t ON p.tab_id = t.id
                       WHERE t.workspace_id = ?)
                    """, [.text(id)]) == SQLITE_OK && ok
                ok = run("DELETE FROM panes WHERE tab_id IN (SELECT id FROM tabs WHERE workspace_id = ?)",
                         [.text(id)]) == SQLITE_OK && ok
                ok = run("DELETE FROM tabs WHERE workspace_id = ?", [.text(id)]) == SQLITE_OK && ok
                ok = run("DELETE FROM windows WHERE workspace_id = ?", [.text(id)]) == SQLITE_OK && ok
                ok = run("DELETE FROM workspaces WHERE id = ?", [.text(id)]) == SQLITE_OK && ok
                return ok
            }
            if committed {
                for paneId in paneIds {
                    Self.removePaneFiles(paneId, scrollbackDir: scrollbackDir,
                                         historyDir: historyDir)
                }
            }
        }
        invalidateWorkspaceCache()
    }

    // MARK: Archive (schema v6 — close = archive, founder-amended FR-56)

    /// On-disk home of one archived session's frozen files:
    /// <archiveDir>/<session-rowid>/{scrollback.txt, history.hist,
    /// history-trimmed.hist}. Files are MOVED here at close (cheap rename,
    /// never a copy); NFR-10 perms (0700 dir / 0600 files) are re-asserted
    /// on every move.
    public static func archiveSessionDir(_ archiveDir: URL, id: Int64) -> URL {
        archiveDir.appendingPathComponent(String(id), isDirectory: true)
    }

    /// Archives every pane of `tabIds` (one sessions row per pane), then
    /// cleans the live rows exactly as forgetTabs did: pane snapshots, panes,
    /// tabs, and any window row left with no tabs. The closed tab must never
    /// RESTORE — but its bytes now live on in the archive instead of dying.
    /// `openedAt` carries per-pane open timestamps when the caller knows them
    /// (the live PaneView's creation time); panes closed before their first
    /// topology capture have no row and archive nothing (the orphan sweep
    /// collects any stray files).
    public func archiveTabs(_ tabIds: [String], closeReason: SessionCloseReason,
                            scrollbackDir: URL?, historyDir: URL?, archiveDir: URL,
                            openedAt: [String: Int] = [:]) {
        guard !tabIds.isEmpty else { return }
        writer.async { [self] in
            let marks = Array(repeating: "?", count: tabIds.count).joined(separator: ",")
            let binds = tabIds.map { Bind.text($0) }
            var paneIds: [String] = []
            query("SELECT id FROM panes WHERE tab_id IN (\(marks))", binds) { stmt in
                if let paneId = column(stmt, 0) { paneIds.append(paneId) }
            }
            performArchive(paneIds: paneIds, alsoDeleteTabs: tabIds,
                           closeReason: closeReason, scrollbackDir: scrollbackDir,
                           historyDir: historyDir, archiveDir: archiveDir,
                           openedAt: openedAt)
        }
    }

    /// Archives exactly these panes (a pane closed inside a still-open tab —
    /// ⌘⇧W / context-menu Close Pane / its shell exiting) and cleans their
    /// live rows as forgetPanes did. The tab row stays: the tab is still open.
    public func archivePanes(_ paneIds: [String], closeReason: SessionCloseReason,
                             scrollbackDir: URL?, historyDir: URL?, archiveDir: URL,
                             openedAt: [String: Int] = [:]) {
        guard !paneIds.isEmpty else { return }
        writer.async { [self] in
            performArchive(paneIds: paneIds, alsoDeleteTabs: [],
                           closeReason: closeReason, scrollbackDir: scrollbackDir,
                           historyDir: historyDir, archiveDir: archiveDir,
                           openedAt: openedAt)
        }
    }

    /// Writer-queue worker: reads each pane's live rows (pane + tab +
    /// workspace join, snapshot, boot uuid) and its command history, inserts
    /// the sessions + FTS rows and deletes the live rows in ONE transaction,
    /// then MOVES the pane's files into <archive>/<rowid>/ — moves happen
    /// only after COMMIT, so a failed transaction never strands files, and a
    /// crash between commit and move leaves files the orphan sweep can see.
    private func performArchive(paneIds: [String], alsoDeleteTabs: [String],
                                closeReason: SessionCloseReason,
                                scrollbackDir: URL?, historyDir: URL?,
                                archiveDir: URL, openedAt: [String: Int]) {
        guard db != nil else { return }
        let now = Int(Date().timeIntervalSince1970)
        var bootUUID: String?
        query("SELECT value FROM meta WHERE key = 'boot_session_uuid'", []) { stmt in
            bootUUID = column(stmt, 0)
        }

        struct Doomed {
            var paneId: String
            var tabId: String
            var workspaceId: String
            var workspaceName: String
            var workspaceColor: String
            var cwd: String?
            var shell: String?
            var customTitle: String?
            var tabColor: String?
            var adapter: String?
            var adapterState: String?
            var commands: String
            var preview: String
        }
        var doomed: [Doomed] = []
        for paneId in paneIds {
            var row: Doomed?
            query("""
                  SELECT p.tab_id, p.shell, p.cwd, t.workspace_id, t.title, t.color,
                         w.name, w.color
                  FROM panes p
                  LEFT JOIN tabs t ON p.tab_id = t.id
                  LEFT JOIN workspaces w ON t.workspace_id = w.id
                  WHERE p.id = ?
                  """, [.text(paneId)]) { stmt in
                row = Doomed(paneId: paneId,
                             tabId: column(stmt, 0) ?? "",
                             workspaceId: column(stmt, 3) ?? Self.defaultWorkspaceId,
                             workspaceName: column(stmt, 6) ?? "",
                             workspaceColor: column(stmt, 7) ?? Self.defaultWorkspaceColor,
                             cwd: column(stmt, 2),
                             shell: column(stmt, 1),
                             customTitle: column(stmt, 4),
                             tabColor: column(stmt, 5),
                             adapter: nil, adapterState: nil,
                             commands: "", preview: "")
            }
            guard var d = row else { continue }  // never captured: nothing to archive
            query("SELECT adapter, adapter_state FROM pane_snapshot WHERE pane_id = ?",
                  [.text(paneId)]) { stmt in
                d.adapter = column(stmt, 0)
                d.adapterState = column(stmt, 1)
            }
            // Command text for FTS + the card preview, from the pane's .hist
            // (freeze-before-trim sidecar first, so rolled-out lines search
            // too). Extended-history prefixes are stripped for the index.
            if let historyDir {
                var lines: [String] = []
                for url in [ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: paneId),
                            ShellIntegration.histFileURL(dir: historyDir, paneId: paneId)] {
                    if let text = try? String(contentsOf: url, encoding: .utf8) {
                        lines.append(contentsOf: text.split(separator: "\n").map(String.init))
                    }
                }
                let commands = lines.compactMap { ShellIntegration.commandText(historyLine: $0) }
                d.commands = commands.joined(separator: "\n")
                d.preview = commands.last ?? ""
            }
            if d.preview.isEmpty { d.preview = d.cwd ?? "" }
            doomed.append(d)
        }

        var movedIds: [(id: Int64, paneId: String)] = []
        let committed = inTransaction {
            var ok = true
            for d in doomed {
                ok = run("""
                    INSERT INTO sessions (pane_id, tab_id, workspace_id, workspace_name,
                        workspace_color, opened_at, closed_at, close_reason, cwd_last,
                        shell, adapter, adapter_state, boot_session_uuid, custom_title,
                        tab_color, preview)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(d.paneId), .text(d.tabId), .text(d.workspaceId),
                          .text(d.workspaceName), .text(d.workspaceColor),
                          openedAt[d.paneId].map(Bind.int) ?? .textOrNull(nil),
                          .int(now), .text(closeReason.rawValue),
                          .textOrNull(d.cwd), .textOrNull(d.shell),
                          .textOrNull(d.adapter), .textOrNull(d.adapterState),
                          .textOrNull(bootUUID), .textOrNull(d.customTitle),
                          .textOrNull(d.tabColor), .text(d.preview)]) == SQLITE_OK && ok
                let rowid = sqlite3_last_insert_rowid(db)
                movedIds.append((rowid, d.paneId))
                if !d.commands.isEmpty {
                    ok = run("INSERT INTO session_fts (session_id, commands) VALUES (?, ?)",
                             [.int(Int(rowid)), .text(d.commands)]) == SQLITE_OK && ok
                }
            }
            // Live-row cleanup, exactly forgetPanes/forgetTabs' shape.
            let paneMarks = Array(repeating: "?", count: paneIds.count).joined(separator: ",")
            let paneBinds = paneIds.map { Bind.text($0) }
            ok = run("DELETE FROM pane_snapshot WHERE pane_id IN (\(paneMarks))", paneBinds) == SQLITE_OK && ok
            ok = run("DELETE FROM panes WHERE id IN (\(paneMarks))", paneBinds) == SQLITE_OK && ok
            if !alsoDeleteTabs.isEmpty {
                let tabMarks = Array(repeating: "?", count: alsoDeleteTabs.count).joined(separator: ",")
                let tabBinds = alsoDeleteTabs.map { Bind.text($0) }
                ok = run("DELETE FROM tabs WHERE id IN (\(tabMarks))", tabBinds) == SQLITE_OK && ok
                ok = run("DELETE FROM windows WHERE id NOT IN (SELECT DISTINCT window_id FROM tabs)") == SQLITE_OK && ok
            }
            return ok
        }
        guard committed else { return }

        let fm = FileManager.default
        for (id, paneId) in movedIds {
            let dir = Self.archiveSessionDir(archiveDir, id: id)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
            var moves: [(URL, String)] = []
            if let scrollbackDir {
                moves.append((ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId),
                              "scrollback.txt"))
            }
            if let historyDir {
                moves.append((ShellIntegration.histFileURL(dir: historyDir, paneId: paneId),
                              "history.hist"))
                moves.append((ShellIntegration.histTrimSidecarURL(dir: historyDir, paneId: paneId),
                              "history-trimmed.hist"))
            }
            for (from, name) in moves where fm.fileExists(atPath: from.path) {
                let to = dir.appendingPathComponent(name)
                try? fm.removeItem(at: to)
                try? fm.moveItem(at: from, to: to)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
            }
        }
    }

    // MARK: Archive reads (timeline / kit surface)

    private func archivedSessionRow(_ stmt: OpaquePointer) -> ArchivedSessionRow? {
        let id = sqlite3_column_int64(stmt, 0)
        guard id > 0 else { return nil }
        let openedAt = sqlite3_column_type(stmt, 6) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int64(stmt, 6))
        let state = (jsonObject(column(stmt, 12)) as? [String: String]) ?? [:]
        return ArchivedSessionRow(
            id: id,
            paneId: column(stmt, 1) ?? "",
            tabId: column(stmt, 2) ?? "",
            workspaceId: column(stmt, 3) ?? "",
            workspaceName: column(stmt, 4) ?? "",
            workspaceColor: column(stmt, 5) ?? "",
            openedAt: openedAt,
            closedAt: Int(sqlite3_column_int64(stmt, 7)),
            closeReason: column(stmt, 8) ?? "",
            cwdLast: column(stmt, 9),
            shell: column(stmt, 10),
            adapter: column(stmt, 11),
            adapterState: state,
            bootSessionUUID: column(stmt, 13),
            customTitle: column(stmt, 14),
            tabColor: column(stmt, 15),
            preview: column(stmt, 16) ?? "")
    }

    private static let sessionColumns = """
        id, pane_id, tab_id, workspace_id, workspace_name, workspace_color,
        opened_at, closed_at, close_reason, cwd_last, shell, adapter,
        adapter_state, boot_session_uuid, custom_title, tab_color, preview
        """

    /// Newest-closed first.
    public func archivedSessions(limit: Int = 50) -> [ArchivedSessionRow] {
        writer.sync {
            var rows: [ArchivedSessionRow] = []
            query("SELECT \(Self.sessionColumns) FROM sessions ORDER BY closed_at DESC, id DESC LIMIT ?",
                  [.int(max(0, limit))]) { stmt in
                if let row = archivedSessionRow(stmt) { rows.append(row) }
            }
            return rows
        }
    }

    public func archivedSession(id: Int64) -> ArchivedSessionRow? {
        writer.sync {
            var row: ArchivedSessionRow?
            query("SELECT \(Self.sessionColumns) FROM sessions WHERE id = ?",
                  [.int(Int(id))]) { stmt in
                row = archivedSessionRow(stmt)
            }
            return row
        }
    }

    public func archivedSessionCount() -> Int {
        writer.sync {
            var n = 0
            query("SELECT COUNT(*) FROM sessions", []) { stmt in
                n = Int(sqlite3_column_int64(stmt, 0))
            }
            return n
        }
    }

    /// FTS5 search over archived command text. User text is tokenized and
    /// each token double-quoted (implicit AND), so raw FTS syntax (`NEAR`,
    /// `*`, unbalanced quotes) can never make the query throw.
    public func searchArchivedSessions(_ text: String, limit: Int = 50) -> [ArchivedSessionRow] {
        // Tokens with no letter/digit ("*", "--") would tokenize to an empty
        // phrase inside the quotes; drop them rather than risk FTS syntax.
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"" }.joined(separator: " ")
        return writer.sync {
            var rows: [ArchivedSessionRow] = []
            query("""
                  SELECT \(Self.sessionColumns) FROM sessions
                  WHERE id IN (SELECT session_id FROM session_fts WHERE session_fts MATCH ?)
                  ORDER BY closed_at DESC, id DESC LIMIT ?
                  """, [.text(match), .int(max(0, limit))]) { stmt in
                if let row = archivedSessionRow(stmt) { rows.append(row) }
            }
            return rows
        }
    }

    /// The frozen scrollback text for one archived session, read from its
    /// archive dir — nil when the session doesn't exist or wrote none. The
    /// row is verified first so a fabricated id can never read outside a
    /// session dir (ids are integers by type; this is belt and suspenders).
    public func archivedScrollbackText(id: Int64, archiveDir: URL) -> String? {
        guard archivedSession(id: id) != nil else { return nil }
        let url = Self.archiveSessionDir(archiveDir, id: id)
            .appendingPathComponent("scrollback.txt")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Archive deletion (the ONLY paths that delete archived bytes)

    /// Writer-queue core: deletes the sessions rows matching `whereSQL`,
    /// their FTS rows, and their archive dirs (dirs after COMMIT).
    private func deleteArchivedRows(whereSQL: String, binds: [Bind], archiveDir: URL) {
        guard db != nil else { return }
        var ids: [Int64] = []
        query("SELECT id FROM sessions WHERE \(whereSQL)", binds) { stmt in
            ids.append(sqlite3_column_int64(stmt, 0))
        }
        guard !ids.isEmpty else { return }
        let committed = inTransaction {
            var ok = true
            ok = run("DELETE FROM session_fts WHERE session_id IN (SELECT id FROM sessions WHERE \(whereSQL))",
                     binds) == SQLITE_OK && ok
            ok = run("DELETE FROM sessions WHERE \(whereSQL)", binds) == SQLITE_OK && ok
            return ok
        }
        if committed {
            for id in ids {
                try? FileManager.default.removeItem(
                    at: Self.archiveSessionDir(archiveDir, id: id))
            }
        }
    }

    /// Per-card Forget (the timeline / kit requestForget path): TRUE
    /// deletion of one archived session — row, FTS entry, and frozen files.
    public func deleteArchivedSession(id: Int64, archiveDir: URL) {
        writer.async { [self] in
            deleteArchivedRows(whereSQL: "id = ?", binds: [.int(Int(id))],
                               archiveDir: archiveDir)
        }
    }

    /// Retention (Settings ▸ Memory): archived sessions older than
    /// `maxAgeDays` are TRUE-deleted at launch. `maxAgeDays <= 0` keeps
    /// everything forever.
    public func enforceArchiveRetention(maxAgeDays: Int, archiveDir: URL) {
        guard maxAgeDays > 0 else { return }
        let cutoff = Int(Date().timeIntervalSince1970) - maxAgeDays * 86_400
        writer.async { [self] in
            deleteArchivedRows(whereSQL: "closed_at < ?", binds: [.int(cutoff)],
                               archiveDir: archiveDir)
        }
    }

    // MARK: Forget (FR-56/57: close = throw it away; kill memories at every granularity)

    /// FR-56/57: purges the journal rows AND scrollback + shell-history files
    /// for exactly these panes. Used both by "Forget Pane Memory" (pane stays
    /// open — the next capture starts a fresh trail) and by user-initiated
    /// pane closes (the pane must never restore). Files are removed only
    /// after the row purge COMMITs, mirroring forgetWorkspace.
    /// `archiveDir` non-nil (the EXPLICIT gesture) also TRUE-deletes any
    /// archived sessions of these panes; nil leaves the archive alone.
    public func forgetPanes(_ paneIds: [String], scrollbackDir: URL?, historyDir: URL? = nil,
                            archiveDir: URL? = nil) {
        guard !paneIds.isEmpty else { return }
        writer.async { [self] in
            let marks = Array(repeating: "?", count: paneIds.count).joined(separator: ",")
            let binds = paneIds.map { Bind.text($0) }
            if let archiveDir {
                deleteArchivedRows(whereSQL: "pane_id IN (\(marks))", binds: binds,
                                   archiveDir: archiveDir)
            }
            let committed = inTransaction {
                var ok = true
                ok = run("DELETE FROM pane_snapshot WHERE pane_id IN (\(marks))", binds) == SQLITE_OK && ok
                ok = run("DELETE FROM panes WHERE id IN (\(marks))", binds) == SQLITE_OK && ok
                return ok
            }
            if committed {
                for paneId in paneIds {
                    Self.removePaneFiles(paneId, scrollbackDir: scrollbackDir,
                                         historyDir: historyDir)
                }
            }
        }
    }

    /// FR-57 "Forget Tab Memory" (the EXPLICIT gesture — a plain user CLOSE
    /// goes through archiveTabs since the founder-amended FR-56): removes
    /// the tab's rows, its panes' rows + snapshots + scrollback and
    /// shell-history files, and any window row left with no tabs — those tabs
    /// must never restore. Quit/switch/park teardown must NOT reach this
    /// (callers gate on their isTerminating / isSwitchingWorkspaces flags).
    /// `archiveDir` non-nil also TRUE-deletes these tabs' archived sessions.
    public func forgetTabs(_ tabIds: [String], scrollbackDir: URL?, historyDir: URL? = nil,
                           archiveDir: URL? = nil) {
        guard !tabIds.isEmpty else { return }
        writer.async { [self] in
            let marks = Array(repeating: "?", count: tabIds.count).joined(separator: ",")
            let binds = tabIds.map { Bind.text($0) }
            if let archiveDir {
                deleteArchivedRows(whereSQL: "tab_id IN (\(marks))", binds: binds,
                                   archiveDir: archiveDir)
            }
            var paneIds: [String] = []
            query("SELECT id FROM panes WHERE tab_id IN (\(marks))", binds) { stmt in
                if let paneId = column(stmt, 0) { paneIds.append(paneId) }
            }
            let committed = inTransaction {
                var ok = true
                ok = run("""
                    DELETE FROM pane_snapshot WHERE pane_id IN
                      (SELECT id FROM panes WHERE tab_id IN (\(marks)))
                    """, binds) == SQLITE_OK && ok
                ok = run("DELETE FROM panes WHERE tab_id IN (\(marks))", binds) == SQLITE_OK && ok
                ok = run("DELETE FROM tabs WHERE id IN (\(marks))", binds) == SQLITE_OK && ok
                // A window row whose tabs are all gone describes nothing.
                ok = run("DELETE FROM windows WHERE id NOT IN (SELECT DISTINCT window_id FROM tabs)") == SQLITE_OK && ok
                return ok
            }
            if committed {
                for paneId in paneIds {
                    Self.removePaneFiles(paneId, scrollbackDir: scrollbackDir,
                                         historyDir: historyDir)
                }
            }
        }
    }

    /// FR-45/57 "Forget Everything": removes the store's entire on-disk
    /// footprint — the db, its WAL/SHM sidecars, the FR-17 generation backups,
    /// any .corrupt remnant, every scrollback file, and every per-pane shell
    /// history file. Call ONLY after the StateStore instance has been released
    /// (its deinit closes the SQLite connection); the caller then constructs a
    /// fresh StateStore and re-captures the live layout so capture continues
    /// cleanly.
    /// `archiveDir` (founder-amended FR-56): Forget Everything empties the
    /// ARCHIVE too — every frozen session dir under it goes.
    public static func purgeAll(dbURL: URL, scrollbackDir: URL, historyDir: URL? = nil,
                                archiveDir: URL? = nil) {
        let fm = FileManager.default
        var doomed = [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm",
                      dbURL.path + ".corrupt"]
        for n in 1...generationCount { doomed.append(generationURL(dbURL, n).path) }
        for path in doomed { try? fm.removeItem(atPath: path) }
        for dir in [scrollbackDir, historyDir, archiveDir].compactMap({ $0 }) {
            if let files = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: nil) {
                for file in files { try? fm.removeItem(at: file) }
            }
        }
    }

    /// FR-57 hygiene: deletes scrollback files (and, when `historyDir` is
    /// given, per-pane .hist files plus their freeze-before-trim sidecars)
    /// whose pane no longer has a row in the panes table (closed panes' files
    /// used to accumulate forever), and (when `archiveDir` is given) archive
    /// session dirs whose rowid has no sessions row — a crash between a
    /// per-card Forget's COMMIT and its dir removal, or a torn archive move,
    /// must never strand frozen bytes.
    /// No-ops on a degraded store — an empty pane set there is ignorance, not
    /// evidence, and must never trigger a mass delete.
    public func purgeOrphanScrollback(dir: URL, historyDir: URL? = nil,
                                      archiveDir: URL? = nil) {
        writer.async { [self] in
            guard db != nil else { return }
            var live = Set<String>()
            var liveHist = Set<String>()
            query("SELECT id FROM panes", []) { stmt in
                // Compare in file-name space: each writer sanitizes ids on
                // write, and the two schemes differ outside ASCII (the .hist
                // name is chosen by the zsh hook), so each gets its own set.
                if let id = column(stmt, 0) {
                    live.insert(ScrollbackText.safePaneId(id))
                    liveHist.insert(ShellIntegration.histSafePaneId(id))
                }
            }
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "txt" {
                    let paneId = file.deletingPathExtension().lastPathComponent
                    if !live.contains(paneId) {
                        try? fm.removeItem(at: file)
                    }
                }
            }
            if let historyDir,
               let files = try? fm.contentsOfDirectory(at: historyDir,
                                                       includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "hist" {
                    let paneId = file.deletingPathExtension().lastPathComponent
                    if !liveHist.contains(paneId) {
                        try? fm.removeItem(at: file)
                    }
                }
                // <pane>.hist.trimmed sidecars orphan with their .hist.
                for file in files where file.pathExtension == "trimmed" {
                    let paneId = file.deletingPathExtension()  // strips .trimmed
                        .deletingPathExtension()               // strips .hist
                        .lastPathComponent
                    if !liveHist.contains(paneId) {
                        try? fm.removeItem(at: file)
                    }
                }
            }
            if let archiveDir {
                var archivedIds = Set<String>()
                query("SELECT id FROM sessions", []) { stmt in
                    archivedIds.insert(String(sqlite3_column_int64(stmt, 0)))
                }
                if let dirs = try? fm.contentsOfDirectory(at: archiveDir,
                                                          includingPropertiesForKeys: nil) {
                    for sessionDir in dirs
                    where !archivedIds.contains(sessionDir.lastPathComponent) {
                        try? fm.removeItem(at: sessionDir)
                    }
                }
            }
        }
    }

    // MARK: Topology

    /// Full rewrite: every workspace's rows are replaced by `windows`.
    /// (Test seam: app code always uses the scoped overload below.)
    public func saveTopology(_ windows: [WindowSnap]) {
        saveTopology(windows, forWorkspaces: nil)
    }

    /// Scoped rewrite: only rows belonging to `scope` workspaces are replaced,
    /// so parked / off-screen workspaces' journal rows survive a capture of
    /// the windows that are actually open. nil scope = full rewrite.
    public func saveTopology(_ windows: [WindowSnap], forWorkspaces scope: Set<String>?) {
        let now = Int(Date().timeIntervalSince1970)
        writer.async { [self] in
            inTransaction {
                var ok = true
                if let scope {
                    let marks = Array(repeating: "?", count: scope.count).joined(separator: ",")
                    let binds = scope.sorted().map { Bind.text($0) }
                    ok = run("""
                        DELETE FROM panes WHERE tab_id IN
                          (SELECT id FROM tabs WHERE workspace_id IN (\(marks)))
                        """, binds) == SQLITE_OK && ok
                    ok = run("DELETE FROM tabs WHERE workspace_id IN (\(marks))", binds) == SQLITE_OK && ok
                    ok = run("DELETE FROM windows WHERE workspace_id IN (\(marks))", binds) == SQLITE_OK && ok
                } else {
                    ok = run("DELETE FROM windows") == SQLITE_OK && ok
                    ok = run("DELETE FROM tabs") == SQLITE_OK && ok
                    ok = run("DELETE FROM panes") == SQLITE_OK && ok
                }
                for (wi, win) in windows.enumerated() {
                    ok = run("INSERT INTO windows (id, frame, ord, focused_tab, workspace_id, updated_at) VALUES (?,?,?,?,?,?)",
                             [.text(win.id), .text(win.frame), .int(wi), .textOrNull(win.focusedTab),
                              .text(win.workspaceId), .int(now)]) == SQLITE_OK && ok
                    for (ti, tab) in win.tabs.enumerated() {
                        let tree = jsonString(tab.tree.toJSONObject()) ?? "{}"
                        ok = run("INSERT INTO tabs (id, window_id, ord, title, split_tree, workspace_id, color, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                                 [.text(tab.id), .text(win.id), .int(ti), .text(tab.title), .text(tree),
                                  .text(win.workspaceId), .textOrNull(tab.color), .int(now)]) == SQLITE_OK && ok
                        for pane in tab.panes {
                            ok = run("INSERT INTO panes (id, tab_id, shell, cwd, cwd_source, updated_at) VALUES (?,?,?,?,?,?)",
                                     [.text(pane.id), .text(tab.id), .textOrNull(pane.shell),
                                      .textOrNull(pane.cwd), .textOrNull(pane.cwdSource), .int(now)]) == SQLITE_OK && ok
                        }
                    }
                }
                // Snapshots for panes that no longer exist go with them.
                ok = run("DELETE FROM pane_snapshot WHERE pane_id NOT IN (SELECT id FROM panes)") == SQLITE_OK && ok
                return ok
            }
        }
    }

    public func updatePaneCwd(_ paneId: String, cwd: String, source: String) {
        let now = Int(Date().timeIntervalSince1970)
        writer.async { [self] in
            run("UPDATE panes SET cwd = ?, cwd_source = ?, updated_at = ? WHERE id = ?",
                [.text(cwd), .text(source), .int(now), .text(paneId)])
        }
    }

    // MARK: Snapshots

    /// `procStart` is the FR-14 PID-reuse guard: the process's kernel start
    /// timestamp captured alongside argv, persisted so a future consumer can
    /// verify it is still talking about the same process.
    public func upsertSnapshot(_ paneId: String, exe: String, argv: [String], pid: pid_t,
                               procStart: Int64 = 0,
                               adapter: String, adapterState: [String: String]) {
        let now = Int(Date().timeIntervalSince1970)
        let argvJSON = jsonString(argv) ?? "[]"
        let stateJSON = jsonString(adapterState) ?? "{}"
        writer.async { [self] in
            run("INSERT OR REPLACE INTO pane_snapshot (pane_id, exe, argv, pid, proc_start, adapter, adapter_state, updated_at) VALUES (?,?,?,?,?,?,?,?)",
                [.text(paneId), .text(exe), .text(argvJSON), .int(Int(pid)),
                 .int(Int(procStart)), .text(adapter), .text(stateJSON), .int(now)])
        }
    }

    public func clearSnapshot(_ paneId: String) {
        writer.async { [self] in
            run("DELETE FROM pane_snapshot WHERE pane_id = ?", [.text(paneId)])
        }
    }

    // MARK: Serial profiles (feature/serial UX: per-device remembered settings)

    public func upsertSerialProfile(_ profile: SerialProfileRow) {
        let now = Int(Date().timeIntervalSince1970)
        writer.async { [self] in
            run("""
                INSERT OR REPLACE INTO serial_profiles
                  (identity, settings, tx, local_echo, last_path, label, updated_at)
                VALUES (?,?,?,?,?,?,?)
                """,
                [.text(profile.identity), .text(profile.settings),
                 .text(profile.txLineEnding), .int(profile.localEcho ? 1 : 0),
                 .text(profile.lastPath), .text(profile.label), .int(now)])
        }
    }

    public func serialProfile(identity: String) -> SerialProfileRow? {
        writer.sync {
            var row: SerialProfileRow?
            query("""
                  SELECT identity, settings, tx, local_echo, last_path, label
                  FROM serial_profiles WHERE identity = ?
                  """, [.text(identity)]) { stmt in
                guard let id = column(stmt, 0), let settings = column(stmt, 1) else { return }
                row = SerialProfileRow(identity: id, settings: settings,
                                       txLineEnding: column(stmt, 2) ?? "crlf",
                                       localEcho: sqlite3_column_int64(stmt, 3) != 0,
                                       lastPath: column(stmt, 4) ?? "",
                                       label: column(stmt, 5) ?? "")
            }
            return row
        }
    }

    // MARK: Load (launch path, synchronous)

    /// `workspaceId` scopes the load to one workspace's windows (the launch
    /// path restores each non-parked workspace this way); nil loads everything.
    public func loadState(workspaceId: String? = nil) -> [WindowRestore] {
        writer.sync {
            var snapshots: [String: SnapshotRow] = [:]
            query("SELECT pane_id, exe, argv, adapter, adapter_state FROM pane_snapshot", []) { stmt in
                guard let paneId = column(stmt, 0), let exe = column(stmt, 1) else { return }
                let argv = (jsonObject(column(stmt, 2)) as? [String]) ?? []
                let adapter = column(stmt, 3) ?? ""
                let state = (jsonObject(column(stmt, 4)) as? [String: String]) ?? [:]
                snapshots[paneId] = SnapshotRow(exe: exe, argv: argv, adapter: adapter,
                                               adapterState: state)
            }

            var panesByTab: [String: [String: PaneRestore]] = [:]
            query("SELECT id, tab_id, shell, cwd FROM panes", []) { stmt in
                guard let id = column(stmt, 0), let tabId = column(stmt, 1) else { return }
                panesByTab[tabId, default: [:]][id] =
                    PaneRestore(cwd: column(stmt, 3), shell: column(stmt, 2), snapshot: snapshots[id])
            }

            var tabsByWindow: [String: [TabRestore]] = [:]
            query("SELECT id, window_id, title, split_tree, color FROM tabs ORDER BY ord", []) { stmt in
                guard let id = column(stmt, 0), let windowId = column(stmt, 1),
                      let treeJSON = jsonObject(column(stmt, 3)),
                      let tree = SplitNode.from(jsonObject: treeJSON) else { return }
                tabsByWindow[windowId, default: []].append(
                    TabRestore(title: column(stmt, 2) ?? "", tree: tree,
                               panes: panesByTab[id] ?? [:], color: column(stmt, 4)))
            }

            var windows: [WindowRestore] = []
            let (sql, binds): (String, [Bind]) = workspaceId.map {
                ("SELECT id, frame, focused_tab FROM windows WHERE workspace_id = ? ORDER BY ord",
                 [Bind.text($0)])
            } ?? ("SELECT id, frame, focused_tab FROM windows ORDER BY ord", [])
            query(sql, binds) { stmt in
                guard let id = column(stmt, 0) else { return }
                let tabs = tabsByWindow[id] ?? []
                guard !tabs.isEmpty else { return }
                windows.append(WindowRestore(frame: column(stmt, 1),
                                             focusedTab: column(stmt, 2), tabs: tabs))
            }
            return windows
        }
    }

    public func counts() -> (windows: Int, tabs: Int, panes: Int) {
        writer.sync {
            func count(_ table: String) -> Int {
                var n = 0
                query("SELECT COUNT(*) FROM \(table)", []) { stmt in
                    n = Int(sqlite3_column_int64(stmt, 0))
                }
                return n
            }
            return (count("windows"), count("tabs"), count("panes"))
        }
    }

    /// Number of pane_snapshot rows — lets tests assert the whole-topology
    /// rewrite leaves no orphaned snapshots.
    public func snapshotCount() -> Int {
        writer.sync {
            var n = 0
            query("SELECT COUNT(*) FROM pane_snapshot", []) { stmt in
                n = Int(sqlite3_column_int64(stmt, 0))
            }
            return n
        }
    }

    /// Runs `block` on the writer queue — used for scrollback file writes so
    /// they serialize with DB writes, and by barrier() below.
    public func onWriter(_ block: @escaping () -> Void) {
        writer.async(execute: block)
    }

    /// Blocks until every queued write has committed (quit/poweroff flush).
    public func barrier() {
        writer.sync {}
    }

    // MARK: SQLite plumbing

    private enum Bind {
        case text(String)
        case textOrNull(String?)
        case int(Int)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Wraps `body` in BEGIN IMMEDIATE … COMMIT with real error handling
    /// (FR-17): a failed BEGIN skips the batch entirely, and a failed
    /// statement or COMMIT rolls back — the previous good rows survive
    /// instead of a half-applied autocommit sequence. Returns true iff the
    /// transaction committed.
    @discardableResult
    private func inTransaction(_ body: () -> Bool) -> Bool {
        guard db != nil else { return false }  // degraded open: silent no-op floor
        let begin = run("BEGIN IMMEDIATE")
        guard begin == SQLITE_OK else {
            NSLog("memterm: BEGIN IMMEDIATE failed (%d) — skipping write batch", begin)
            return false
        }
        if body(), run("COMMIT") == SQLITE_OK {
            return true
        }
        NSLog("memterm: transaction failed — rolled back")
        run("ROLLBACK")
        return false
    }

    @discardableResult
    private func run(_ sql: String, _ binds: [Bind] = []) -> Int32 {
        guard let db else { return SQLITE_ERROR }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return sqlite3_errcode(db)
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        let rc = sqlite3_step(stmt)
        return (rc == SQLITE_DONE || rc == SQLITE_ROW) ? SQLITE_OK : rc
    }

    private func query(_ sql: String, _ binds: [Bind], row: (OpaquePointer) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        while sqlite3_step(stmt) == SQLITE_ROW, let stmt { row(stmt) }
    }

    private func bind(_ stmt: OpaquePointer?, _ binds: [Bind]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .textOrNull(let s?): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .textOrNull(nil): sqlite3_bind_null(stmt, idx)
            case .int(let n): sqlite3_bind_int64(stmt, idx, Int64(n))
            }
        }
    }

    private func column(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func jsonObject(_ s: String?) -> Any? {
        guard let s, let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
