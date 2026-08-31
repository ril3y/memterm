import AppKit
import MemtermCore
import SwiftTerm

// The capture side of the memory engine (§7.3): layout on every mutation,
// kernel cwd + foreground process every 2 s, scrollback every 5 s when
// changed, full flush on quit and poweroff. All UI reads happen on the main
// thread; all disk writes go through the StateStore writer queue.

final class MemoryEngine {
    let store: StateStore
    private unowned let app: MemtermAppDelegate
    private let scrollbackLines: Int
    /// Exposed so workspace-forget can purge scrollback files (FR-57).
    let scrollbackDir: URL

    private var pollTimer: Timer?
    private var scrollbackTimer: Timer?
    private var topologyDebounce: DispatchWorkItem?
    private var frameDebounce: DispatchWorkItem?
    private var lastScrollbackHash: [String: Int] = [:]

    static var baseDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memterm")
    }

    init(app: MemtermAppDelegate, config: Config) {
        self.app = app
        self.scrollbackLines = config.scrollbackLines
        self.scrollbackDir = MemoryEngine.baseDir.appendingPathComponent("scrollback")
        try? FileManager.default.createDirectory(at: scrollbackDir,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        store = StateStore(url: MemoryEngine.baseDir.appendingPathComponent("state.db"))
        if let bootUUID = ProcessInspector.bootSessionUUID() {
            store.setMeta("boot_session_uuid", bootUUID)
        }
    }

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
        scrollbackTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveScrollback(force: false)
        }
    }

    // MARK: - Topology (FR-12)

    func scheduleTopologySave() {
        guard !app.isTerminating, !app.isSwitchingWorkspaces else { return }
        topologyDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveTopologyNow() }
        topologyDebounce = work
        // Near-immediate; the tiny delay coalesces bursts (split + focus).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Window move/resize (debounced ~1 s).
    func scheduleFrameSave() {
        guard !app.isTerminating, !app.isSwitchingWorkspaces else { return }
        frameDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveTopologyNow() }
        frameDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Saves are scoped to the workspaces whose windows can be on screen, so
    /// a capture never erases a parked / switched-away workspace's rows.
    func saveTopologyNow() {
        guard !app.isTerminating, !app.isSwitchingWorkspaces else { return }
        store.saveTopology(snapshotTopology(), forWorkspaces: app.captureScope())
    }

    /// Native tabs are separate NSWindows sharing a tab group, so a "window"
    /// row is a tab group and each controller is a tab.
    static func groupedControllers(_ controllers: [TerminalWindowController])
        -> [[TerminalWindowController]] {
        var groups: [[TerminalWindowController]] = []
        var seen = Set<ObjectIdentifier>()
        for controller in controllers {
            guard let window = controller.window else { continue }
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                let gid = ObjectIdentifier(tabGroup)
                guard !seen.contains(gid) else { continue }
                seen.insert(gid)
                let members = tabGroup.windows.compactMap { tabWindow in
                    controllers.first { $0.window === tabWindow }
                }
                if !members.isEmpty { groups.append(members) }
            } else {
                groups.append([controller])
            }
        }
        return groups
    }

    private func snapshotTopology() -> [WindowSnap] {
        MemoryEngine.groupedControllers(app.controllers).compactMap { members in
            let tabs = members.compactMap { $0.snapshotTab() }
            guard !tabs.isEmpty, let firstWindow = members[0].window else { return nil }
            let f = firstWindow.frame
            let frame = "\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height))"
            let focused = members.first { $0.window?.tabGroup?.selectedWindow === $0.window
                                          || members.count == 1 }?.tabId
            return WindowSnap(id: tabs[0].id, frame: frame, focusedTab: focused, tabs: tabs,
                              workspaceId: members[0].workspaceId)
        }
    }

    // MARK: - Kernel poll (FR-13/14)

    func pollNow() {
        guard !app.isTerminating else { return }
        for controller in app.controllers {
            for pane in controller.allPanes() {
                pollPane(pane)
            }
        }
    }

    private func pollPane(_ pane: PaneView) {
        guard let process = pane.process, process.running else { return }
        let shellPid = process.shellPid

        // cwd: kernel truth first, OSC 7 as corroboration/fallback.
        if let cwd = ProcessInspector.cwd(of: shellPid) {
            pane.lastKnownCwd = cwd
            pane.cwdSource = "kernel"
            store.updatePaneCwd(pane.paneId, cwd: cwd, source: "kernel")
        } else if let cwd = pane.currentLocalDirectory {
            pane.lastKnownCwd = cwd
            pane.cwdSource = "osc7"
            store.updatePaneCwd(pane.paneId, cwd: cwd, source: "osc7")
        }

        // Foreground job via the pty master; shell's child as fallback.
        var fgPid = ProcessInspector.foregroundPgid(masterFd: process.childfd)
        if fgPid == nil || fgPid == shellPid {
            fgPid = nil
        }
        if fgPid == nil {
            fgPid = ProcessInspector.childPids(of: shellPid).first
        }
        guard let pid = fgPid, pid != shellPid,
              let argv = ProcessInspector.argv(of: pid), !argv.isEmpty else {
            store.clearSnapshot(pane.paneId)
            return
        }
        let exe = argv[0]
        if let hit = Adapters.classify(argv: argv, cwd: pane.lastKnownCwd) {
            store.upsertSnapshot(pane.paneId, exe: exe, argv: argv, pid: pid,
                                 adapter: hit.adapter, adapterState: hit.state)
        } else {
            store.upsertSnapshot(pane.paneId, exe: exe, argv: argv, pid: pid,
                                 adapter: "", adapterState: [:])
        }
    }

    // MARK: - Scrollback (FR-16, v0: plain text, change-detected)

    func saveScrollback(force: Bool) {
        guard force || !app.isTerminating else { return }
        for controller in app.controllers {
            for pane in controller.allPanes() {
                let text = pane.scrollbackText(maxLines: scrollbackLines)
                let hash = text.hashValue
                if !force && lastScrollbackHash[pane.paneId] == hash { continue }
                lastScrollbackHash[pane.paneId] = hash
                let url = scrollbackURL(for: pane.paneId)
                store.onWriter {
                    try? text.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    func scrollbackURL(for paneId: String) -> URL {
        ScrollbackText.fileURL(dir: scrollbackDir, paneId: paneId)
    }

    func loadScrollback(for paneId: String) -> String? {
        try? String(contentsOf: scrollbackURL(for: paneId), encoding: .utf8)
    }

    // MARK: - Restore support

    func loadStateForRestore() -> [WindowRestore] {
        store.loadState()
    }

    // MARK: - Flush (quit / poweroff)

    /// Call BEFORE isTerminating is set: windows must still be open so the
    /// final topology snapshot captures them, not their teardown.
    func flushSync() {
        pollNow()
        store.saveTopology(snapshotTopology(), forWorkspaces: app.captureScope())
        saveScrollback(force: true)
        store.barrier()
    }
}
