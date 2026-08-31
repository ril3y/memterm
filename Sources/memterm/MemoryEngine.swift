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
    private var loggedScrollbackWriteFailure = false
    /// FR-18: same-boot vs reboot, decided by comparing the STORED boot UUID
    /// against the live one before the new value is stamped (same UX in v0.1;
    /// prerequisite for FR-28's HUD and the v0.4 adopt-vs-resurrect branch).
    let launchKind: LaunchKind

    /// MEMTERM_STATE_DIR overrides the state location so --smoke (and tests)
    /// run hermetically instead of rewriting the founder's real journal.
    static var baseDir: URL {
        if let override = ProcessInfo.processInfo.environment["MEMTERM_STATE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("memterm")
    }

    init(app: MemtermAppDelegate, config: Config) {
        self.app = app
        self.scrollbackLines = config.scrollbackLines
        self.scrollbackDir = MemoryEngine.baseDir.appendingPathComponent("scrollback")
        try? FileManager.default.createDirectory(at: scrollbackDir,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // createDirectory applies the attributes to the leaf only; the base
        // dir (which holds state.db and its WAL sidecars) needs 0700 too
        // (NFR-10 — plaintext scrollback must not be other-user readable).
        for dir in [MemoryEngine.baseDir, scrollbackDir] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: dir.path)
        }
        store = StateStore(url: MemoryEngine.baseDir.appendingPathComponent("state.db"))
        let liveBootUUID = ProcessInspector.bootSessionUUID()
        launchKind = BootSession.launchKind(
            storedBootUUID: store.getMeta("boot_session_uuid"),
            liveBootUUID: liveBootUUID)
        if let liveBootUUID {
            store.setMeta("boot_session_uuid", liveBootUUID)
        }
    }

    func start() {
        // .common mode: the default mode starves timers while menus track or
        // a modal alert runs — exactly when a crash would flush stale state.
        let poll = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
        let scrollback = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveScrollback(force: false)
        }
        RunLoop.main.add(scrollback, forMode: .common)
        scrollbackTimer = scrollback
        // Launch-time sweep: scrollback files for panes the journal no longer
        // references (closed panes, old sessions) are deleted, not hoarded.
        store.purgeOrphanScrollback(dir: scrollbackDir)
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
        // FR-14 PID-reuse guard: bracket the argv read with proc_start reads —
        // if the pid was recycled between tcgetpgrp and here (or mid-read),
        // the start time changes and the sample is dropped rather than
        // attributing another process's argv to this pane.
        guard let pid = fgPid, pid != shellPid,
              let procStart = ProcessInspector.startTime(of: pid),
              let argv = ProcessInspector.argv(of: pid), !argv.isEmpty,
              ProcessInspector.startTime(of: pid) == procStart else {
            store.clearSnapshot(pane.paneId)
            return
        }
        let exe = argv[0]
        if let hit = Adapters.classify(argv: argv, cwd: pane.lastKnownCwd) {
            store.upsertSnapshot(pane.paneId, exe: exe, argv: argv, pid: pid,
                                 procStart: procStart,
                                 adapter: hit.adapter, adapterState: hit.state)
        } else {
            store.upsertSnapshot(pane.paneId, exe: exe, argv: argv, pid: pid,
                                 procStart: procStart,
                                 adapter: "", adapterState: [:])
        }
    }

    // MARK: - Scrollback (FR-16, v0: plain text, change-detected)

    func saveScrollback(force: Bool) {
        guard force || !app.isTerminating else { return }
        var livePaneIds = Set<String>()
        for controller in app.controllers {
            for pane in controller.allPanes() {
                livePaneIds.insert(pane.paneId)
                let text = pane.scrollbackText(maxLines: scrollbackLines)
                let hash = text.hashValue
                if !force && lastScrollbackHash[pane.paneId] == hash { continue }
                let url = scrollbackURL(for: pane.paneId)
                let paneId = pane.paneId
                store.onWriter { [weak self] in
                    do {
                        try text.write(to: url, atomically: true, encoding: .utf8)
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: 0o600], ofItemAtPath: url.path)
                        // Change-detection hash advances only after the bytes
                        // actually landed — a failed write retries next tick.
                        DispatchQueue.main.async {
                            self?.lastScrollbackHash[paneId] = hash
                        }
                    } catch {
                        DispatchQueue.main.async {
                            guard let self, !self.loggedScrollbackWriteFailure else { return }
                            self.loggedScrollbackWriteFailure = true
                            NSLog("memterm: scrollback write failed (%@) — capture degraded",
                                  error.localizedDescription)
                        }
                    }
                }
            }
        }
        // Closed panes never come back: drop their change-detection entries.
        lastScrollbackHash = lastScrollbackHash.filter { livePaneIds.contains($0.key) }
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
        // Queued after the topology rewrite on the writer queue, so the sweep
        // sees the final pane set: files for user-closed panes go now (FR-56
        // "close forgets" applies to the bytes, not just the rows).
        store.purgeOrphanScrollback(dir: scrollbackDir)
        store.barrier()
    }
}
