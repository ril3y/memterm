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

    /// Per-tab shell history (.hist files, written by the zsh hooks; FR-56/57
    /// delete them alongside scrollback).
    let historyDir: URL
    /// The ZDOTDIR wrapper dir panes spawn with. nil = shell_integration off,
    /// or the install failed (never point ZDOTDIR at a half-written dir — a
    /// missing .zshrc there would silently skip the user's rc).
    let shellIntegrationDir: URL?

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
        self.historyDir = MemoryEngine.baseDir.appendingPathComponent("history")
        for dir in [scrollbackDir, historyDir] {
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
        }
        // createDirectory applies the attributes to the leaf only; the base
        // dir (which holds state.db and its WAL sidecars) needs 0700 too
        // (NFR-10 — plaintext scrollback must not be other-user readable).
        for dir in [MemoryEngine.baseDir, scrollbackDir, historyDir] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: dir.path)
        }
        // Shell integration (FR-5 / per-tab history): the wrapper files are
        // rewritten at every launch so they always match this build
        // (version-stamped). Installed even with shell_integration = false so
        // flipping it on in Settings works for new panes without a relaunch —
        // the SPAWN path is what the config key gates. Lives under the state
        // dir, so MEMTERM_STATE_DIR isolation covers it too.
        let integrationDir = MemoryEngine.baseDir.appendingPathComponent("shell-integration")
        shellIntegrationDir = ShellIntegration.install(into: integrationDir)
            ? integrationDir : nil
        if shellIntegrationDir == nil {
            NSLog("memterm: shell-integration install failed at %@ — panes spawn plain",
                  integrationDir.path)
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
        // Launch-time sweep: scrollback/.hist files for panes the journal no
        // longer references (closed panes, old sessions) are deleted, not
        // hoarded.
        store.purgeOrphanScrollback(dir: scrollbackDir, historyDir: historyDir)
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

    /// FR-59: grouping and focus come from app.captureGroups() — first-class
    /// model state (each host's ordered tabs + selection), read identically
    /// for visible hosts and hidden holders. The journal's tab/pane ids are
    /// the controllers' own, unchanged across the custom-chrome migration, so
    /// a pre-migration state.db restores as-is (PreMigrationRestoreTests).
    private func snapshotTopology() -> [WindowSnap] {
        app.captureGroups().compactMap { group in
            let tabs = group.members.compactMap { $0.snapshotTab() }
            guard !tabs.isEmpty, let firstWindow = group.members[0].window else { return nil }
            let f = firstWindow.frame
            let frame = "\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width)),\(Int(f.height))"
            return WindowSnap(id: tabs[0].id, frame: frame, focusedTab: group.focusedTabId,
                              tabs: tabs, workspaceId: group.members[0].workspaceId)
        }
    }

    // MARK: - Kernel poll (FR-13/14)

    func pollNow() {
        guard !app.isTerminating else { return }
        // app.controllers, never visible windows: hidden workspaces' panes
        // (FR-59) are live and keep being captured exactly like visible ones.
        for controller in app.controllers {
            for pane in controller.allPanes() {
                pollPane(pane)
            }
        }
    }

    private func pollPane(_ pane: PaneView) {
        // feature/serial: a serial pane has no shell/pty — its snapshot is the
        // 'serial' adapter with port identity + line settings, so restore can
        // surface the consent-gated reconnect offer. Journaled whether or not
        // the device is currently attached (the identity is the memory).
        if let serial = pane as? SerialPaneView {
            store.upsertSnapshot(pane.paneId, exe: "", argv: [], pid: 0, procStart: 0,
                                 adapter: SerialAdapter.name,
                                 adapterState: serial.adapterStateForJournal())
            return
        }
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
        // app.controllers: hidden workspaces' scrollback keeps flushing (FR-59).
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

    // MARK: - Forget (FR-56/57)

    /// FR-57 "Forget Pane Memory" and FR-56 pane close: rows + scrollback +
    /// shell-history files for one pane go now. For an open pane the next
    /// capture tick starts a fresh trail (the hash reset forces the rewrite
    /// through; the zsh hook recreates the .hist on the next command).
    func forgetPane(_ paneId: String) {
        store.forgetPanes([paneId], scrollbackDir: scrollbackDir, historyDir: historyDir)
        lastScrollbackHash[paneId] = nil
    }

    /// FR-56 deliberate tab close / FR-57 "Forget Tab Memory": the tab's rows,
    /// its panes, their snapshots, and their scrollback + history files.
    func forgetTab(tabId: String, paneIds: [String]) {
        store.forgetTabs([tabId], scrollbackDir: scrollbackDir, historyDir: historyDir)
        for paneId in paneIds { lastScrollbackHash[paneId] = nil }
    }

    /// FR-45/57 "Forget Everything" step 1: stop the capture timers and drain
    /// queued writes so the caller can release this engine and purge the state
    /// dir with no writer racing the deletes.
    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        scrollbackTimer?.invalidate()
        scrollbackTimer = nil
        topologyDebounce?.cancel()
        frameDebounce?.cancel()
        store.barrier()
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
        store.purgeOrphanScrollback(dir: scrollbackDir, historyDir: historyDir)
        store.barrier()
    }
}
