import AppKit
import MemtermCore

// Interactive-mode application delegate: config, main menu, window/tab/pane
// lifecycle. The probe modes (--latency/--flood) keep their own bare delegate
// in App.swift.

final class MemtermAppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.load()
    private(set) var controllers: [TerminalWindowController] = []
    private var fontSize: CGFloat
    private(set) var memory: MemoryEngine?
    /// Set before windows close at quit so their teardown isn't captured.
    private(set) var isTerminating = false
    private let smokeMode: Bool
    /// FR-36/§9: offer-time registry ensuring one `--resume <uuid>` per UUID
    /// across every restore path (launch, workspace switch, unpark).
    let claudeClaims = ClaudeSessionClaims()

    // -- Workspaces (Group G) --
    /// The workspace whose tabs the user is working in right now.
    var activeWorkspaceId = StateStore.defaultWorkspaceId
    /// Workspaces with windows on screen this session; scopes topology saves
    /// so switched-away / parked workspaces' journal rows are never erased.
    var materializedWorkspaceIds: Set<String> = []
    /// Set while a switch/park tears windows down so the closes aren't
    /// captured as topology mutations (same idea as isTerminating).
    var isSwitchingWorkspaces = false
    /// Shell ▸ Workspace submenu; rebuilt in place whenever workspaces change
    /// so its ⌃⌘n key equivalents stay live (FR-52).
    let workspaceMenu = NSMenu(title: "Workspace")

    /// The workspaces a topology capture may rewrite: everything that is (or
    /// was, this session) on screen. Parked and never-opened workspaces stay out.
    func captureScope() -> Set<String> {
        var scope = materializedWorkspaceIds
        scope.insert(activeWorkspaceId)
        for controller in controllers { scope.insert(controller.workspaceId) }
        return scope
    }

    init(smokeMode: Bool = false) {
        self.smokeMode = smokeMode
        fontSize = CGFloat(config.fontSize)
        super.init()
    }

    func currentFont() -> NSFont {
        config.resolveFont(size: fontSize)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu(for: self)

        // FR-24: one restore pipeline, exercised on every normal launch.
        let engine = MemoryEngine(app: self, config: config)
        memory = engine

        // FR-51: reboot-restore restores workspaces, not bare tabs — every
        // non-parked workspace's windows come back; parked ones stay in the
        // switcher menu, ready to reopen.
        let workspaces = engine.store.listWorkspaces()
        var active = engine.store.getMeta("active_workspace_id")
            ?? StateStore.defaultWorkspaceId
        if !workspaces.contains(where: { $0.id == active && !$0.isParked }) {
            active = workspaces.first(where: { !$0.isParked })?.id
                ?? workspaces.first?.id ?? StateStore.defaultWorkspaceId
        }
        activeWorkspaceId = active
        if workspaces.first(where: { $0.id == active })?.isParked == true {
            // Everything was parked: the active one reopens so a window exists.
            engine.store.setWorkspaceParked(active, parked: false)
        }
        var restoredAnything = false
        for workspace in engine.store.listWorkspaces() where !workspace.isParked {
            let restored = engine.store.loadState(workspaceId: workspace.id)
            guard !restored.isEmpty else { continue }
            restoreWindows(restored, workspaceId: workspace.id)
            materializedWorkspaceIds.insert(workspace.id)
            restoredAnything = true
        }
        materializedWorkspaceIds.insert(activeWorkspaceId)
        if controllers.isEmpty {
            openNewWindow()
        } else {
            focusWindows(ofWorkspace: activeWorkspaceId)
        }
        rebuildWorkspaceMenu()
        engine.start()
        engine.scheduleTopologySave()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification, object: nil)

        NSApp.activate(ignoringOtherApps: true)
        if smokeMode { runSmoke(restoredAnything: restoredAnything) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        memory?.flushSync()   // windows still open: the snapshot is the live layout
        isTerminating = true
        return .terminateNow
    }

    @objc private func workspaceWillPowerOff(_ note: Notification) {
        memory?.flushSync()
    }

    // MARK: - Restore

    func restoreWindows(_ windows: [WindowRestore], workspaceId: String) {
        var focusTarget: TerminalWindowController?
        for win in windows {
            var host: TerminalWindowController?
            for (i, tab) in win.tabs.enumerated() {
                let frame = i == 0 ? parseFrame(win.frame) : nil
                let controller = TerminalWindowController(app: self, workspaceId: workspaceId,
                                                          restoredTab: tab,
                                                          restoredFrame: frame)
                controllers.append(controller)
                if i == 0 {
                    host = controller
                } else if let hostWindow = host?.window, let newWindow = controller.window {
                    hostWindow.addTabbedWindow(newWindow, ordered: .above)
                }
                controller.showWindow(nil)
                if controller.tabId == win.focusedTab || focusTarget == nil {
                    focusTarget = controller
                }
            }
        }
        focusTarget?.window?.makeKeyAndOrderFront(nil)
        refreshWorkspaceChips()
    }

    private func parseFrame(_ s: String?) -> NSRect? {
        guard let s else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 50, parts[3] > 50 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    // MARK: - Smoke test (deterministic capture/restore gate, no interaction)

    private func runSmoke(restoredAnything: Bool) {
        // Hermetic by default: main.swift points MEMTERM_STATE_DIR at a temp
        // location for --smoke, so the gate never rewrites the real journal.
        print("SMOKE-STATE-DIR \(MemoryEngine.baseDir.path)")
        if !restoredAnything {
            // Run 1: build 1 window / 2 tabs / 3 panes, cd one pane, let the
            // 2 s poll capture it, flush, report what the store holds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.controllers.first?.splitCurrentPane(vertical: true)
                self.newWindowForTab(nil)
                self.controllers.first?.allPanes().first?.send(txt: "cd /tmp\r")
            }
            var workspaceB: String?
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                self.memory?.flushSync()
                guard let counts = self.memory?.store.counts() else { exit(1) }
                print("SMOKE-SAVED windows=\(counts.windows) tabs=\(counts.tabs) panes=\(counts.panes)")
                // Workspace leg (FR-49..51): create B and switch to it — the
                // switch captures + closes Default's windows and opens B fresh.
                workspaceB = self.createWorkspace(named: "B")
                if let b = workspaceB { self.switchToWorkspace(b) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.3) {
                // Switch back: Default's tabs come back through the standard
                // restore pipeline (ghost scrollback + offers included).
                self.switchToWorkspace(StateStore.defaultWorkspaceId)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) {
                guard let engine = self.memory, let b = workspaceB else { exit(1) }
                self.parkWorkspace(b)
                engine.flushSync()
                let list = engine.store.listWorkspaces()
                let parked = list.filter(\.isParked).count
                let activeTabs = engine.store.loadState(workspaceId: self.activeWorkspaceId)
                    .reduce(0) { $0 + $1.tabs.count }
                print("SMOKE-WS workspaces=\(list.count) parked=\(parked) active_tabs=\(activeTabs)")
            }
            // FR-56 leg: deliberately close one tab (the single-pane one) —
            // a user gesture, so it must be forgotten. Run 2 asserts it is
            // NOT restored while everything else is.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.9) {
                guard let doomed = self.controllers.first(where: {
                    $0.workspaceId == self.activeWorkspaceId && $0.allPanes().count == 1
                }) else {
                    print("SMOKE-FAIL no single-pane tab to close")
                    exit(1)
                }
                print("SMOKE-CLOSED tab=\(doomed.tabId)")
                doomed.close()  // neither isTerminating nor isSwitchingWorkspaces: forgets
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.7) {
                guard let engine = self.memory else { exit(1) }
                engine.flushSync()
                let counts = engine.store.counts()
                print("SMOKE-AFTER-CLOSE windows=\(counts.windows) tabs=\(counts.tabs) panes=\(counts.panes)")
                exit(0)  // exit() skips teardown — the closest thing to a crash
            }
        } else {
            // Run 2: report what the restore pipeline actually rebuilt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let windows = MemoryEngine.groupedControllers(self.controllers).count
                let panes = self.controllers.flatMap { $0.allPanes() }
                let cwds = panes.compactMap { $0.lastKnownCwd }
                print("SMOKE-RESTORED windows=\(windows) tabs=\(self.controllers.count) panes=\(panes.count) cwds=\(cwds)")
                // Workspace assertions: parked B is listed but NOT restored.
                guard let store = self.memory?.store else { exit(1) }
                let list = store.listWorkspaces()
                guard let b = list.first(where: { $0.name == "B" }), b.isParked else {
                    print("SMOKE-FAIL workspace B missing or not parked")
                    exit(1)
                }
                if self.controllers.contains(where: { $0.workspaceId == b.id }) {
                    print("SMOKE-FAIL parked workspace B was restored")
                    exit(1)
                }
                // FR-56: the deliberately-closed tab from run 1 must NOT be
                // restored, while the split tab (2 panes) is.
                if self.controllers.count != 1 || panes.count != 2 {
                    print("SMOKE-FAIL close-forget: expected 1 tab / 2 panes restored, got \(self.controllers.count) tab(s) / \(panes.count) pane(s)")
                    exit(1)
                }
                let parked = list.filter(\.isParked).count
                print("SMOKE-WS workspaces=\(list.count) parked=\(parked) active_tabs=\(self.controllers.count)")
                exit(0)
            }
        }
    }

    // MARK: - Window / tab plumbing

    @discardableResult
    func openNewWindow(in workspaceId: String? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController(app: self,
                                                  workspaceId: workspaceId ?? activeWorkspaceId)
        controllers.append(controller)
        controller.showWindow(nil)
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
        return controller
    }

    func controllerClosed(_ controller: TerminalWindowController) {
        controllers.removeAll { $0 === controller }
    }

    func keyController() -> TerminalWindowController? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let controller = controllers.first(where: { $0.window === window }) {
            return controller
        }
        return controllers.first
    }

    // MARK: - Menu actions

    @objc func newWindow(_ sender: Any?) {
        openNewWindow()
    }

    /// Standard tab mechanism: ⌘T and the native tab bar's "+" both land here.
    /// The new tab joins the host window's workspace (FR-49).
    @objc func newWindowForTab(_ sender: Any?) {
        let hostController = keyController()
        let controller = TerminalWindowController(
            app: self, workspaceId: hostController?.workspaceId ?? activeWorkspaceId)
        controllers.append(controller)
        if let host = hostController?.window, let newWindow = controller.window {
            host.addTabbedWindow(newWindow, ordered: .above)
        }
        controller.showWindow(nil)
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
    }

    @objc func splitRight(_ sender: Any?) {
        keyController()?.splitCurrentPane(vertical: true)
    }

    @objc func splitDown(_ sender: Any?) {
        keyController()?.splitCurrentPane(vertical: false)
    }

    @objc func closePane(_ sender: Any?) {
        keyController()?.closeCurrentPane()
    }

    @objc func focusPaneLeft(_ sender: Any?) { keyController()?.moveFocus(.left) }
    @objc func focusPaneRight(_ sender: Any?) { keyController()?.moveFocus(.right) }
    @objc func focusPaneUp(_ sender: Any?) { keyController()?.moveFocus(.up) }
    @objc func focusPaneDown(_ sender: Any?) { keyController()?.moveFocus(.down) }

    @objc func openPreferences(_ sender: Any?) {
        NSWorkspace.shared.open(Config.configURL)
    }

    @objc func increaseFontSize(_ sender: Any?) { changeFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { changeFontSize(by: -1) }

    private func changeFontSize(by delta: CGFloat) {
        fontSize = min(72, max(6, fontSize + delta))
        let font = currentFont()
        for controller in controllers { controller.applyFont(font) }
    }

    @objc func clearBuffer(_ sender: Any?) {
        keyController()?.currentPane()?.clearScrollback()
    }

    // FR-4: ⌘F/⌘G/⌘⇧G route to the focused pane's find bar (FindBar.swift).
    // While the search field has focus, currentPane() still resolves to its
    // host pane via the controller's focusedPane tracking.
    @objc func findInPane(_ sender: Any?) {
        keyController()?.currentPane()?.openFindBar()
    }

    @objc func findNextInPane(_ sender: Any?) {
        keyController()?.currentPane()?.findNextMatch()
    }

    @objc func findPreviousInPane(_ sender: Any?) {
        keyController()?.currentPane()?.findPreviousMatch()
    }

    // MARK: - Kill memories (FR-57)

    /// Rows + scrollback file for the focused pane; the pane stays open and
    /// capture continues with a fresh trail.
    @objc func forgetPaneMemory(_ sender: Any?) {
        guard let pane = keyController()?.currentPane() else { return }
        memory?.forgetPane(pane.paneId)
    }

    @objc func forgetTabMemory(_ sender: Any?) {
        guard let controller = keyController() else { return }
        memory?.forgetTab(tabId: controller.tabId,
                          paneIds: controller.allPanes().map { $0.paneId })
    }

    /// FR-45/57 global wipe, confirmation-gated.
    @objc func forgetEverythingAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Forget everything?"
        alert.informativeText = """
            Deletes all of memterm's memory — layouts, scrollback history, \
            session records. Open terminals stay open.
            """
        alert.addButton(withTitle: "Forget Everything")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        forgetEverything()
    }

    /// Purges the state dir contents (db + generations + scrollback files),
    /// starts a fresh StateStore, and re-captures the currently-open layout so
    /// capture continues cleanly. Workspace rows for windows that stay open
    /// are re-created first (a window's workspace id lives for the window's
    /// life); everything else — parked workspaces included — is gone.
    func forgetEverything() {
        guard memory != nil else { return }
        let openIds = Set(controllers.map { $0.workspaceId })
        // No local strong reference to the engine: the store's deinit (which
        // closes the SQLite connection) must run when `memory` is nilled,
        // BEFORE purgeAll deletes the files under it.
        let openWorkspaces = memory!.store.listWorkspaces().filter { openIds.contains($0.id) }
        let dbURL = MemoryEngine.baseDir.appendingPathComponent("state.db")
        let scrollbackDir = memory!.scrollbackDir
        memory?.shutdown()  // timers off, writer queue drained
        memory = nil        // releases the engine → StateStore deinit closes the db
        StateStore.purgeAll(dbURL: dbURL, scrollbackDir: scrollbackDir)

        let fresh = MemoryEngine(app: self, config: config)
        memory = fresh
        for workspace in openWorkspaces where workspace.id != StateStore.defaultWorkspaceId {
            fresh.store.createWorkspace(id: workspace.id, name: workspace.name,
                                        color: workspace.color)
        }
        if !openIds.contains(activeWorkspaceId) {
            activeWorkspaceId = openIds.first ?? StateStore.defaultWorkspaceId
        }
        materializedWorkspaceIds = openIds.union([activeWorkspaceId])
        fresh.store.setMeta("active_workspace_id", activeWorkspaceId)
        fresh.start()
        fresh.flushSync()   // the open layout is memory again, from this moment
        rebuildWorkspaceMenu()
    }

    /// ⌘R: types the captured resume command into the pty WITHOUT a newline —
    /// the user must press Enter themselves (FR-29, no exceptions).
    @objc func typeResumeCommand(_ sender: Any?) {
        guard let pane = keyController()?.currentPane(),
              let command = pane.pendingResumeCommand else { return }
        pane.send(txt: command)
        pane.pendingResumeCommand = nil
    }
}
