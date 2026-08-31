import AppKit
import MemtermCore

// Interactive-mode application delegate: config, main menu, window/tab/pane
// lifecycle. The probe modes (--latency/--flood) keep their own bare delegate
// in App.swift.

final class MemtermAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var config = Config.load()
    private var settingsController: SettingsWindowController?
    private var tabRenameClickMonitor: Any?
    private var tabContextMenuMonitor: Any?
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
    /// Set while park/forget tear windows down (and around a switch's
    /// hide/show transition) so those events aren't captured as topology
    /// mutations (same idea as isTerminating).
    var isSwitchingWorkspaces = false
    /// Shell ▸ Workspace submenu; rebuilt in place whenever workspaces change
    /// so its ⌃⌘n key equivalents stay live (FR-52).
    let workspaceMenu = NSMenu(title: "Workspace")

    // -- FR-59: non-destructive switching state --
    /// Tab-group layout of each workspace hidden by switchToWorkspace, keyed
    /// by workspace id. Needed because orderOut() dissolves native tab groups
    /// (verified empirically on macOS 26.2): the show path regroups from this,
    /// and captureGroups() uses it so a hidden workspace's topology keeps
    /// journaling as the tab groups it had on screen.
    var hiddenLayouts: [String: HiddenWorkspaceLayout] = [:]
    /// Workspaces most-recently switched AWAY from, newest first — the pick
    /// order when the active workspace's last visible window closes and a
    /// hidden workspace must be surfaced (FR-59 corollary).
    var workspaceMRU: [String] = []

    /// The workspaces a topology capture may rewrite: everything that is (or
    /// was, this session) on screen. Parked and never-opened workspaces stay out.
    /// Hidden workspaces stay IN: their windows are live and still captured.
    func captureScope() -> Set<String> {
        var scope = materializedWorkspaceIds
        scope.insert(activeWorkspaceId)
        for controller in controllers { scope.insert(controller.workspaceId) }
        return scope
    }

    /// The controller groups a topology capture should treat as windows, with
    /// the focused tab per group. Visible windows group by their live native
    /// tab group; HIDDEN windows group by the layout recorded when they were
    /// ordered out (their live tab groups are dissolved — see hiddenLayouts).
    func captureGroups() -> [CaptureGroup] {
        var groups: [CaptureGroup] = []
        var claimed = Set<ObjectIdentifier>()
        for workspaceId in hiddenLayouts.keys.sorted() {
            guard let layout = hiddenLayouts[workspaceId] else { continue }
            for group in layout.groups {
                let members = group.tabIds.compactMap { tabId in
                    controllers.first { $0.tabId == tabId && $0.workspaceId == workspaceId }
                }
                guard !members.isEmpty else { continue }
                for member in members { claimed.insert(ObjectIdentifier(member)) }
                let focused = group.selectedTabId.flatMap { id in
                    members.contains { $0.tabId == id } ? id : nil
                }
                groups.append(CaptureGroup(members: members,
                                           focusedTabId: focused ?? members[0].tabId))
            }
        }
        let rest = controllers.filter { !claimed.contains(ObjectIdentifier($0)) }
        for group in MemoryEngine.groupedControllers(rest) {
            let focused = group.first { $0.window?.tabGroup?.selectedWindow === $0.window
                                        || group.count == 1 }?.tabId
            groups.append(CaptureGroup(members: group, focusedTabId: focused))
        }
        return groups
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

        // Double-click on a tab in the native tab bar renames it. The tab bar
        // is private AppKit, so the gesture is caught with a local monitor:
        // the first click of the double-click already selected the clicked
        // tab (making it the key window), so renaming the key controller
        // renames the tab the user double-clicked. Clicks in the titlebar
        // proper (above the tab strip) keep the system zoom behavior.
        tabRenameClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, event.clickCount == 2,
                  self.tabStripController(for: event) != nil else { return event }
            DispatchQueue.main.async { self.keyController()?.promptRenameTab() }
            return nil  // swallow: nothing else should react to this gesture
        }

        // Founder UX stage: right-click on the tab strip pops OUR tab menu
        // (the native tab context menu is private AppKit — established at the
        // FR-58 stage — so it can't be extended, only replaced). The event is
        // swallowed so the private menu doesn't double-show; clicks outside
        // the strip region (titlebar proper, workspace bar, content) pass
        // through untouched, keeping any native behavior there.
        tabContextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
            [weak self] event in
            guard let self, let controller = self.tabStripController(for: event)
            else { return event }
            self.showTabContextMenu(for: controller, event: event)
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        if smokeMode { runSmoke(restoredAnything: restoredAnything) }
        // MEMTERM_UI_PROBE=1: geometry self-check for the titlebar surfaces
        // (workspace bar under the tab strip, tab accessory) — the headless
        // stand-in for eyeballing when no screen capture is available.
        if ProcessInfo.processInfo.environment["MEMTERM_UI_PROBE"] == "1" { runUIProbe() }
    }

    private func runUIProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.newWindowForTab(nil)  // second tab so the tab bar is visible
            _ = self.createWorkspace(named: "Probe")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard let controller = self.keyController(), let window = controller.window else {
                print("UIPROBE-FAIL no window"); exit(1)
            }
            let bar = controller.workspaceBar
            let barFrame = bar.map { $0.convert($0.bounds, to: nil) } ?? .zero
            let content = window.contentLayoutRect
            print("UIPROBE window_h=\(Int(window.frame.height)) content_maxY=\(Int(content.maxY))")
            print("UIPROBE bar_frame=\(Int(barFrame.minX)),\(Int(barFrame.minY)),\(Int(barFrame.width)),\(Int(barFrame.height)) in_window=\(bar?.window === window)")
            print("UIPROBE tabstrip_bottom=\(Int(controller.tabStripBottomY())) tab_bar_visible=\(window.tabGroup?.isTabBarVisible == true)")
            print("UIPROBE chips=\(bar?.chipTitlesForProbe() ?? []) accessory_set=\(window.tab.accessoryView != nil)")
        }
        // Activity-indicator leg: output lands on the FIRST tab while the
        // second (created above) is selected → active → decays to unseen →
        // clears when the tab is selected.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.controllers.first?.allPanes().first?.send(txt: "echo probe-activity\r")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            print("UIPROBE-ACT after_output=\(self.controllers.first.map { $0.activityStateForProbe() } ?? .idle)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.4) {
            print("UIPROBE-ACT after_decay=\(self.controllers.first.map { $0.activityStateForProbe() } ?? .idle)")
            self.controllers.first?.window?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.8) {
            print("UIPROBE-ACT after_select=\(self.controllers.first.map { $0.activityStateForProbe() } ?? .idle)")
            exit(0)
        }
    }

    // MARK: - Tab-strip gestures (shared region logic for both monitors)

    /// The tab this gesture applies to, when the event lands on the native
    /// tab strip of one of our windows: between the top of the workspace bar
    /// (or contentLayoutRect.maxY when the bar is hidden) and the bottom of
    /// the titlebar proper. Returns the controller of the window that
    /// received the event — the selected tab of its group.
    private func tabStripController(for event: NSEvent) -> TerminalWindowController? {
        guard let window = event.window,
              window.tabGroup?.isTabBarVisible == true,
              let controller = controllers.first(where: { $0.window === window })
        else { return nil }
        let y = event.locationInWindow.y
        let tabStripBottom = controller.tabStripBottomY()
        let titlebarBottom = window.frame.height - 28
        guard y >= tabStripBottom, y <= titlebarBottom else { return nil }
        return controller
    }

    /// Founder UX stage: our tab context menu. A right-click can't select a
    /// private tab item, so it applies to the SELECTED tab of the clicked
    /// window group — the disabled header names it to keep the target
    /// unambiguous.
    private func showTabContextMenu(for controller: TerminalWindowController, event: NSEvent) {
        let menu = NSMenu(title: "Tab")
        let header = NSMenuItem(title: "Tab “\(controller.window?.title ?? "memterm")”",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = MoveTabRequest(controller: controller, workspaceId: nil)
            menu.addItem(item)
        }
        add("Rename Tab…", #selector(ctxTabRename(_:)))
        let moveItem = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
        moveItem.submenu = makeMoveTabSubmenu(for: controller)
        menu.addItem(moveItem)
        add("New Workspace from Tab…", #selector(newWorkspaceFromTabItem(_:)))
        menu.addItem(.separator())
        add("Forget Tab Memory", #selector(ctxTabForget(_:)))
        menu.addItem(.separator())
        add("Close Tab", #selector(ctxTabClose(_:)))

        guard let contentView = event.window?.contentView else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: contentView)
    }

    @objc private func ctxTabRename(_ sender: NSMenuItem) {
        (sender.representedObject as? MoveTabRequest)?.controller?.promptRenameTab()
    }

    /// FR-57 for the clicked tab (same semantics as Shell ▸ Forget Tab
    /// Memory: rows + scrollback files go now, capture restarts fresh).
    @objc private func ctxTabForget(_ sender: NSMenuItem) {
        guard let controller = (sender.representedObject as? MoveTabRequest)?.controller
        else { return }
        memory?.forgetTab(tabId: controller.tabId,
                          paneIds: controller.allPanes().map { $0.paneId })
    }

    /// FR-56: closing from the menu is a user gesture — windowWillClose runs
    /// the standard forget path.
    @objc private func ctxTabClose(_ sender: NSMenuItem) {
        (sender.representedObject as? MoveTabRequest)?.controller?.close()
    }

    /// FR-59 corollary: hidden live controllers keep the app alive — closing
    /// the last VISIBLE window must never quit while other workspaces hold
    /// live (hidden) windows. With no controllers left at all, quit as before.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        controllers.isEmpty
    }

    /// Called from windowWillClose after the controller is deregistered. When
    /// a user gesture closed the active workspace's last visible window and
    /// hidden live windows exist elsewhere, surface the most recently used
    /// hidden workspace instead of sitting windowless (FR-59 corollary). The
    /// switch is deferred: never re-enter window plumbing from inside a close.
    func activeWorkspaceWindowClosed(_ workspaceId: String, userInitiated: Bool) {
        guard userInitiated, workspaceId == activeWorkspaceId,
              !controllers.contains(where: { $0.workspaceId == workspaceId }),
              !controllers.isEmpty else { return }
        let hidden = Set(controllers.map { $0.workspaceId })
        guard let pick = SwitchSupport.mruPick(candidates: hidden,
                                               mostRecentFirst: workspaceMRU) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  !self.controllers.contains(where: { $0.workspaceId == self.activeWorkspaceId }),
                  self.controllers.contains(where: { $0.workspaceId == pick })
            else { return }
            self.switchToWorkspace(pick)
        }
    }

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

    /// FR-59 frame stability, resurrect path: the journaled frame is used
    /// as-is; only a frame that would land fully off every screen is adjusted
    /// (monitor unplugged since capture). The pure containment/clamp logic is
    /// SwitchSupport.adjustedFrame, unit-tested headlessly.
    private func parseFrame(_ s: String?) -> NSRect? {
        guard let s else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 50, parts[3] > 50 else { return nil }
        let frame = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
        return SwitchSupport.adjustedFrame(frame,
                                           visibleFrames: NSScreen.screens.map(\.visibleFrame))
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
            // FR-59 live-switch leg state: Default's identity before switching.
            var defaultControllerIds = Set<ObjectIdentifier>()
            var defaultPids: [pid_t] = []
            var defaultFrame = NSRect.zero
            func defaultControllers() -> [TerminalWindowController] {
                self.controllers.filter { $0.workspaceId == StateStore.defaultWorkspaceId }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                self.memory?.flushSync()
                guard let counts = self.memory?.store.counts() else { exit(1) }
                print("SMOKE-SAVED windows=\(counts.windows) tabs=\(counts.tabs) panes=\(counts.panes)")
                // FR-59 leg: record Default's controllers, shell pids, and
                // frame, then switch to a fresh workspace B. The switch must
                // HIDE Default — same objects, processes untouched.
                let defaults = defaultControllers()
                defaultControllerIds = Set(defaults.map(ObjectIdentifier.init))
                defaultPids = defaults.flatMap { $0.allPanes() }
                    .compactMap { $0.process?.shellPid }
                defaultFrame = defaults.first?.window?.frame ?? .zero
                workspaceB = self.createWorkspace(named: "B")
                if let b = workspaceB { self.switchToWorkspace(b) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.3) {
                // Hidden, not closed: windows off screen, shells alive,
                // controllers still registered.
                let defaults = defaultControllers()
                let hidden = !defaults.isEmpty
                    && defaults.allSatisfy { $0.window?.isVisible != true }
                let alive = defaultPids.allSatisfy { kill($0, 0) == 0 }
                let sameObjects = Set(defaults.map(ObjectIdentifier.init)) == defaultControllerIds
                guard hidden, alive, sameObjects else {
                    print("SMOKE-FAIL live-switch hide: hidden=\(hidden) alive=\(alive) sameObjects=\(sameObjects)")
                    exit(1)
                }
                // Switch back: hide/show, NOT the restore pipeline.
                self.switchToWorkspace(StateStore.defaultWorkspaceId)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) {
                let defaults = defaultControllers()
                let sameObjects = Set(defaults.map(ObjectIdentifier.init)) == defaultControllerIds
                let visible = defaults.contains { $0.window?.isVisible == true }
                let survivors = defaultPids.filter { kill($0, 0) == 0 }.count
                let dividers = defaults.flatMap { $0.allPanes() }
                    .reduce(0) { $0 + $1.restoredDividerCount }
                let framesStable = defaults.first?.window?.frame == defaultFrame
                guard sameObjects, visible, survivors == defaultPids.count,
                      !defaultPids.isEmpty, dividers == 0, framesStable else {
                    print("SMOKE-FAIL live-switch show: sameObjects=\(sameObjects) visible=\(visible) pids=\(survivors)/\(defaultPids.count) dividers=\(dividers) framesStable=\(framesStable)")
                    exit(1)
                }
                print("SMOKE-LIVE-SWITCH pids_survived=\(survivors) frames_stable=\(framesStable)")
            }
            // Park leg (FR-51): B — hidden but live — gets parked, which DOES
            // close its windows (the explicit destructive-but-remembered
            // gesture), so both switch semantics are exercised in one run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.9) {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.7) {
                guard let doomed = self.controllers.first(where: {
                    $0.workspaceId == self.activeWorkspaceId && $0.allPanes().count == 1
                }) else {
                    print("SMOKE-FAIL no single-pane tab to close")
                    exit(1)
                }
                print("SMOKE-CLOSED tab=\(doomed.tabId)")
                doomed.close()  // active-workspace user close: forgets
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) {
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

    /// `new_tab_same_cwd` (iTerm2's "reuse previous session's directory"):
    /// the key pane's kernel-truth cwd, for ⌘T/⌘N to inherit. Kernel poll
    /// first (works with zero shell integration), OSC 7 fallback for a pane
    /// younger than the first 2 s poll tick.
    private func inheritedCwd() -> String? {
        guard config.newTabSameCwd, let pane = keyController()?.currentPane()
        else { return nil }
        return pane.lastKnownCwd ?? pane.currentLocalDirectory
    }

    @objc func newWindow(_ sender: Any?) {
        let controller = TerminalWindowController(app: self, workspaceId: activeWorkspaceId,
                                                  initialCwd: inheritedCwd())
        controllers.append(controller)
        controller.showWindow(nil)
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
    }

    /// Standard tab mechanism: ⌘T and the native tab bar's "+" both land here.
    /// The new tab joins the host window's workspace (FR-49).
    @objc func newWindowForTab(_ sender: Any?) {
        let hostController = keyController()
        let controller = TerminalWindowController(
            app: self, workspaceId: hostController?.workspaceId ?? activeWorkspaceId,
            initialCwd: inheritedCwd())
        controllers.append(controller)
        if let host = hostController?.window, let newWindow = controller.window {
            host.addTabbedWindow(newWindow, ordered: .above)
        }
        controller.showWindow(nil)
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
    }

    @objc func renameTab(_ sender: Any?) {
        keyController()?.promptRenameTab()
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

    /// ⌘, — the real settings UI (FR-44/48). The config file stays the source
    /// of truth; the window reads it and writes through Config.save.
    @objc func openPreferences(_ sender: Any?) {
        if settingsController == nil {
            settingsController = SettingsWindowController(app: self)
        }
        settingsController?.show()
    }

    @objc func openConfigFile(_ sender: Any?) {
        NSWorkspace.shared.open(Config.configURL)
    }

    /// Settings changes land here: adopt, apply to every open pane, persist.
    /// Font/colors/copy-on-select take effect immediately; scrollback and
    /// shell only shape panes created from now on.
    func applyConfigLive(_ newConfig: Config) {
        config = newConfig
        fontSize = CGFloat(newConfig.fontSize)
        let font = currentFont()
        for controller in controllers {
            controller.applyFont(font)
            controller.applyTheme(config)
            // Safe to call per controller: applyTabBarPolicy checks the live
            // bar state, so the first controller of a group flips it and the
            // rest no-op.
            controller.applyTabBarPolicy(alwaysShow: config.alwaysShowTabBar)
        }
        refreshWorkspaceChips()  // workspace_bar visibility follows the config
        config.save()
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

// MARK: - FR-59 supporting types

/// The native-tab-group layout of a workspace at the moment it was hidden:
/// per group, the member tabIds in strip order and the selected tab, plus
/// which tab held key status. Recorded by hideWindows, consumed by
/// showHiddenWindows (regrouping) and captureGroups (topology fidelity),
/// because orderOut() dissolves live tab groups.
struct HiddenWorkspaceLayout {
    struct Group {
        var tabIds: [String]
        var selectedTabId: String?
    }

    var groups: [Group]
    var keyTabId: String?
}

/// One journal "window": the tab controllers that form (or formed, while
/// hidden) a native tab group, plus its focused tab.
struct CaptureGroup {
    let members: [TerminalWindowController]
    let focusedTabId: String?
}
