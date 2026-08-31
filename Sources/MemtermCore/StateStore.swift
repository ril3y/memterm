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

    public init(id: String, title: String, tree: SplitNode, panes: [PaneSnap]) {
        self.id = id
        self.title = title
        self.tree = tree
        self.panes = panes
    }
}

public struct WindowSnap {
    public var id: String
    public var frame: String  // "x,y,w,h"
    public var focusedTab: String?
    public var tabs: [TabSnap]

    public init(id: String, frame: String, focusedTab: String?, tabs: [TabSnap]) {
        self.id = id
        self.frame = frame
        self.focusedTab = focusedTab
        self.tabs = tabs
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

    public init(title: String, tree: SplitNode, panes: [String: PaneRestore]) {
        self.title = title
        self.tree = tree
        self.panes = panes
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

    public init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            db = nil
            return
        }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS windows (id TEXT PRIMARY KEY, frame TEXT, ord INTEGER,
                                            focused_tab TEXT, updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS tabs (id TEXT PRIMARY KEY, window_id TEXT, ord INTEGER,
                                         title TEXT, split_tree TEXT, updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS panes (id TEXT PRIMARY KEY, tab_id TEXT, shell TEXT,
                                          cwd TEXT, cwd_source TEXT, updated_at INTEGER);
        CREATE TABLE IF NOT EXISTS pane_snapshot (pane_id TEXT PRIMARY KEY, exe TEXT,
                                                  argv TEXT, pid INTEGER, adapter TEXT,
                                                  adapter_state TEXT, updated_at INTEGER);
        """)
        setMeta("schema_version", "1")
    }

    deinit {
        sqlite3_close(db)
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

    // MARK: Topology

    public func saveTopology(_ windows: [WindowSnap]) {
        let now = Int(Date().timeIntervalSince1970)
        writer.async { [self] in
            run("BEGIN IMMEDIATE")
            run("DELETE FROM windows")
            run("DELETE FROM tabs")
            run("DELETE FROM panes")
            for (wi, win) in windows.enumerated() {
                run("INSERT INTO windows (id, frame, ord, focused_tab, updated_at) VALUES (?,?,?,?,?)",
                    [.text(win.id), .text(win.frame), .int(wi), .textOrNull(win.focusedTab), .int(now)])
                for (ti, tab) in win.tabs.enumerated() {
                    let tree = jsonString(tab.tree.toJSONObject()) ?? "{}"
                    run("INSERT INTO tabs (id, window_id, ord, title, split_tree, updated_at) VALUES (?,?,?,?,?,?)",
                        [.text(tab.id), .text(win.id), .int(ti), .text(tab.title), .text(tree), .int(now)])
                    for pane in tab.panes {
                        run("INSERT INTO panes (id, tab_id, shell, cwd, cwd_source, updated_at) VALUES (?,?,?,?,?,?)",
                            [.text(pane.id), .text(tab.id), .textOrNull(pane.shell),
                             .textOrNull(pane.cwd), .textOrNull(pane.cwdSource), .int(now)])
                    }
                }
            }
            // Snapshots for panes that no longer exist go with them.
            run("DELETE FROM pane_snapshot WHERE pane_id NOT IN (SELECT id FROM panes)")
            run("COMMIT")
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

    public func upsertSnapshot(_ paneId: String, exe: String, argv: [String], pid: pid_t,
                               adapter: String, adapterState: [String: String]) {
        let now = Int(Date().timeIntervalSince1970)
        let argvJSON = jsonString(argv) ?? "[]"
        let stateJSON = jsonString(adapterState) ?? "{}"
        writer.async { [self] in
            run("INSERT OR REPLACE INTO pane_snapshot (pane_id, exe, argv, pid, adapter, adapter_state, updated_at) VALUES (?,?,?,?,?,?,?)",
                [.text(paneId), .text(exe), .text(argvJSON), .int(Int(pid)),
                 .text(adapter), .text(stateJSON), .int(now)])
        }
    }

    public func clearSnapshot(_ paneId: String) {
        writer.async { [self] in
            run("DELETE FROM pane_snapshot WHERE pane_id = ?", [.text(paneId)])
        }
    }

    // MARK: Load (launch path, synchronous)

    public func loadState() -> [WindowRestore] {
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
            query("SELECT id, window_id, title, split_tree FROM tabs ORDER BY ord", []) { stmt in
                guard let id = column(stmt, 0), let windowId = column(stmt, 1),
                      let treeJSON = jsonObject(column(stmt, 3)),
                      let tree = SplitNode.from(jsonObject: treeJSON) else { return }
                tabsByWindow[windowId, default: []].append(
                    TabRestore(title: column(stmt, 2) ?? "", tree: tree,
                               panes: panesByTab[id] ?? [:]))
            }

            var windows: [WindowRestore] = []
            query("SELECT id, frame, focused_tab FROM windows ORDER BY ord", []) { stmt in
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

    private func run(_ sql: String, _ binds: [Bind] = []) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        sqlite3_step(stmt)
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
