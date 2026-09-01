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
        run("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', '5')")
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
    /// for the per-tab shell history) its .hist file. Both live under the state
    /// dir and both die with the same forget gestures.
    private static func removePaneFiles(_ paneId: String, scrollbackDir: URL?,
                                        historyDir: URL?) {
        if let scrollbackDir {
            try? FileManager.default.removeItem(
                at: ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId))
        }
        if let historyDir {
            try? FileManager.default.removeItem(
                at: ShellIntegration.histFileURL(dir: historyDir, paneId: paneId))
        }
    }

    /// FR-50/57 "forget": purges the workspace's journal rows AND its panes'
    /// scrollback + shell-history files on disk — forgetting deletes bytes,
    /// not just the index. Files are removed only after the row purge COMMITs,
    /// so a failed transaction never leaves rows pointing at deleted files.
    public func forgetWorkspace(_ id: String, scrollbackDir: URL?, historyDir: URL? = nil) {
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

    // MARK: Forget (FR-56/57: close = throw it away; kill memories at every granularity)

    /// FR-56/57: purges the journal rows AND scrollback + shell-history files
    /// for exactly these panes. Used both by "Forget Pane Memory" (pane stays
    /// open — the next capture starts a fresh trail) and by user-initiated
    /// pane closes (the pane must never restore). Files are removed only
    /// after the row purge COMMITs, mirroring forgetWorkspace.
    public func forgetPanes(_ paneIds: [String], scrollbackDir: URL?, historyDir: URL? = nil) {
        guard !paneIds.isEmpty else { return }
        writer.async { [self] in
            let marks = Array(repeating: "?", count: paneIds.count).joined(separator: ",")
            let binds = paneIds.map { Bind.text($0) }
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

    /// FR-56: a user-initiated tab close (⌘W, the tab's close button)
    /// removes the tab's rows, its panes' rows + snapshots + scrollback and
    /// shell-history files, and any window row left with no tabs — those tabs
    /// must never restore. Quit/switch/park teardown must NOT reach this
    /// (callers gate on their isTerminating / isSwitchingWorkspaces flags).
    public func forgetTabs(_ tabIds: [String], scrollbackDir: URL?, historyDir: URL? = nil) {
        guard !tabIds.isEmpty else { return }
        writer.async { [self] in
            let marks = Array(repeating: "?", count: tabIds.count).joined(separator: ",")
            let binds = tabIds.map { Bind.text($0) }
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
    public static func purgeAll(dbURL: URL, scrollbackDir: URL, historyDir: URL? = nil) {
        let fm = FileManager.default
        var doomed = [dbURL.path, dbURL.path + "-wal", dbURL.path + "-shm",
                      dbURL.path + ".corrupt"]
        for n in 1...generationCount { doomed.append(generationURL(dbURL, n).path) }
        for path in doomed { try? fm.removeItem(atPath: path) }
        for dir in [scrollbackDir, historyDir].compactMap({ $0 }) {
            if let files = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: nil) {
                for file in files { try? fm.removeItem(at: file) }
            }
        }
    }

    /// FR-57 hygiene: deletes scrollback files (and, when `historyDir` is
    /// given, per-pane .hist files) whose pane no longer has a row in the
    /// panes table (closed panes' files used to accumulate forever).
    /// No-ops on a degraded store — an empty pane set there is ignorance, not
    /// evidence, and must never trigger a mass delete.
    public func purgeOrphanScrollback(dir: URL, historyDir: URL? = nil) {
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
