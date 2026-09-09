import AppKit
import MemtermCore

// Interactive-mode application delegate: config, main menu, window/tab/pane
// lifecycle. The probe modes (--latency/--flood) keep their own bare delegate
// in App.swift.

final class MemtermAppDelegate: NSObject, NSApplicationDelegate {
    private(set) var config = Config.load()
    private var settingsController: SettingsWindowController?
    /// Every live TAB (TerminalWindowController is the TabModel now). This is
    /// the capture/poll/scrollback iteration surface — hidden workspaces'
    /// tabs keep being captured because iteration is over the model, not
    /// windows (FR-59).
    private(set) var controllers: [TerminalWindowController] = []
    /// Every live window host (custom-tab-chrome stage). Hosts of hidden
    /// workspaces stay registered while their windows are ordered out.
    private(set) var hosts: [WindowHostController] = []
    /// The model's own notion of the focused host. NSApp.keyWindow can be nil
    /// or stale whenever the app is not the ACTIVE app (activation denied —
    /// probe/smoke runs launched from a shell hit this), so every deliberate
    /// focus (windowDidBecomeKey, showWindow, focusWindow()) records here and
    /// keyHost() prefers it over guessing by workspace.
    private(set) weak var lastFocusedHost: WindowHostController?

    func noteHostFocused(_ host: WindowHostController) {
        lastFocusedHost = host
    }
    private var fontSize: CGFloat
    private(set) var memory: MemoryEngine?
    /// Set before windows close at quit so their teardown isn't captured.
    private(set) var isTerminating = false
    /// Explicit smoke run selection (--smoke=save / --smoke=verify), nil for
    /// interactive/probe launches.
    private let smokeRun: SmokeRun?
    private var smokeMode: Bool { smokeRun != nil }
    /// FR-36/§9: offer-time registry ensuring one `--resume <uuid>` per UUID
    /// across every restore path (launch, workspace switch, unpark).
    let claudeClaims = ClaudeSessionClaims()
    /// ExtensionKit v0: the app-side Host implementation + registries for the
    /// compiled-in extension targets (none yet — the kit dry-runs its API
    /// against tests until MemtermClaudeBrowser lands).
    private(set) var extensionRuntime: ExtensionHostRuntime?

    // -- Serial (feature/serial UX) --
    /// One app-wide hotplug watcher, started lazily by the first serial pane
    /// or connect sheet. Watching never opens a device (IOKit registry only);
    /// events route to serial panes (live reconnect) and the open sheet.
    private var serialHotplug: SerialHotplugWatcher?
    /// The open connect sheet, if any (its port list follows hotplug live).
    private var serialSheet: SerialConnectSheetController?

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
    /// Workspaces most-recently switched AWAY from, newest first — the pick
    /// order when the active workspace's last visible window closes and a
    /// hidden workspace must be surfaced (FR-59 corollary).
    var workspaceMRU: [String] = []

    // -- Switch crossfade (founder: the hard cut on switch felt un-macOS) --
    /// Fade only for real interactive switches: never in smoke/headless runs
    /// (assertions read state synchronously) and never under Reduce Motion.
    var switchFadeEnabled: Bool {
        !smokeMode && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    /// Set for the duration of a fading switch so every window-presenting path
    /// (show-hidden, resurrect, fresh window) starts its windows at alpha 0;
    /// the switch then animates them to 1 over the outgoing windows.
    var fadeInPending = false

    // -- Workspace activity (founder UX: hidden workspaces show output) --
    /// Per-workspace output marks behind the chip pulse/ring
    /// (MemtermCore.WorkspaceActivityCenter — pure decay/coalescing state).
    private var workspaceActivity = WorkspaceActivityCenter()
    private var workspaceActivityWork: DispatchWorkItem?

    /// The workspaces a topology capture may rewrite: everything that is (or
    /// was, this session) on screen. Parked and never-opened workspaces stay out.
    /// Hidden workspaces stay IN: their windows are live and still captured.
    func captureScope() -> Set<String> {
        var scope = materializedWorkspaceIds
        scope.insert(activeWorkspaceId)
        for controller in controllers { scope.insert(controller.workspaceId) }
        return scope
    }

    /// The tab groups a topology capture should treat as windows, with the
    /// focused tab per group. Under custom chrome this is first-class model
    /// state: each host's ordered tab list + its selected tab — visible or
    /// hidden alike (hidden hosts keep their tabs; nothing dissolves).
    func captureGroups() -> [CaptureGroup] {
        var groups: [CaptureGroup] = []
        var claimed = Set<ObjectIdentifier>()
        for host in hosts where !host.tabs.isEmpty {
            for tab in host.tabs { claimed.insert(ObjectIdentifier(tab)) }
            groups.append(CaptureGroup(members: host.tabs,
                                       focusedTabId: host.selectedTab?.tabId
                                           ?? host.tabs[0].tabId))
        }
        // Safety net: a tab mid-re-homing (no host) still journals alone.
        for controller in controllers where !claimed.contains(ObjectIdentifier(controller)) {
            groups.append(CaptureGroup(members: [controller],
                                       focusedTabId: controller.tabId))
        }
        return groups
    }

    init(smokeRun: SmokeRun? = nil) {
        self.smokeRun = smokeRun
        fontSize = CGFloat(config.fontSize)
        super.init()
    }

    func currentFont() -> NSFont {
        config.resolveFont(size: fontSize)
    }

    /// Chrome-row sizing (chips, pills, row heights) derived from the
    /// CONFIGURED terminal size — Settings › Appearance › Size — never the
    /// transient ⌘+/⌘- zoom (founder bug 2026-09-09: chrome ignored Size).
    var chromeMetrics: ChromeMetrics {
        .derived(fromTerminalFontSize: config.fontSize)
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

        // ExtensionKit v0: build the Host and activate the compiled-in
        // extension list (empty until the Claude-browser stage).
        let runtime = ExtensionHostRuntime(app: self)
        extensionRuntime = runtime
        runtime.activateCompiledIn()
        // Registered extension panels join the Window menu (⌘⇧C for the
        // Claude Sessions browser — verified unclaimed in MainMenu).
        if let windowMenu = NSApp.windowsMenu {
            runtime.installPanelMenuItems(into: windowMenu)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification, object: nil)

        // Custom-tab-chrome stage: the tab strip is OURS now — double-click
        // rename, right-click menus, hover ✕, and drag reorder are handled by
        // TabStripView/TabItemView directly. The two NSEvent local monitors
        // (and their tab-strip band geometry) that reverse-engineered the
        // private native tab bar are gone.

        // Quiet mode (TESTING.md §2.5): automated runs never steal the
        // screen. Focus assertions ride on lastFocusedHost (keyHost()'s
        // fallback when activation is denied).
        if !ProbeSupport.quiet {
            NSApp.activate(ignoringOtherApps: true)
        }
        if let run = smokeRun { runSmoke(run: run, restoredAnything: restoredAnything) }
        // MEMTERM_UI_PROBE=1: harness v2 (TESTING.md §2) — gesture routing,
        // presented geometry, and rendered pixels, in fresh AND restored
        // worlds, under the sentinel protocol.
        if ProbeSupport.isUIProbe { runUIProbe() }
    }


    // MARK: - Tab context menu (built by TabStripView per right-click)

    /// Our tab context menu, now targeting the CLICKED tab directly — the
    /// custom strip can hit-test tab bodies, which the private native bar
    /// never allowed (right-clicks used to apply to the selected tab).
    func makeTabContextMenu(for controller: TerminalWindowController) -> NSMenu {
        let menu = NSMenu(title: "Tab")
        let header = NSMenuItem(title: "Tab “\(controller.displayTitle)”",
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
        // Founder 2026-08-31: per-tab colors from the tab's own menu.
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "Color")
        for preset in Self.workspaceColorPresets {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(TerminalWindowController.ctxSetTabColor(_:)),
                                  keyEquivalent: "")
            item.target = controller
            item.representedObject = preset.hex
            item.image = Self.chipImage(hex: preset.hex)
            item.state = controller.tabColor == preset.hex ? .on : .off
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        let none = NSMenuItem(title: "None",
                              action: #selector(TerminalWindowController.ctxSetTabColor(_:)),
                              keyEquivalent: "")
        none.target = controller
        none.representedObject = ""
        none.state = controller.tabColor == nil ? .on : .off
        colorMenu.addItem(none)
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        menu.addItem(.separator())
        add("Forget Tab Memory", #selector(ctxTabForget(_:)))
        // ExtensionKit: registered extension items (enumerable, typed — no
        // authority beyond their own closures). No-op while none registered.
        extensionRuntime?.appendTabMenuItems(to: menu)
        menu.addItem(.separator())
        add("Close Tab", #selector(ctxTabClose(_:)))
        return menu
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
    /// In probe/smoke runs NEVER auto-quit (TESTING.md §2.1): a mid-run empty
    /// app must reach the atexit ABORT guard as a FAIL, not read as a clean
    /// early exit — bug 4's false-green path.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if ProbeSupport.isUIProbe || smokeMode { return false }
        return controllers.isEmpty
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

    // MARK: - Workspace activity (founder: "the ping command always creates
    // activity — the non-front workspace should blink the color circle")

    /// Called (coalesced upstream per tab, and again per workspace by the
    /// center) from every pane's pty output. The ACTIVE workspace never
    /// marks — the user is looking at it.
    func workspaceProducedOutput(_ workspaceId: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if workspaceActivity.recordOutput(workspace: workspaceId, at: now,
                                          isActiveWorkspace: workspaceId == activeWorkspaceId) {
            refreshWorkspaceActivity()
        } else {
            scheduleWorkspaceActivityRefresh(after: workspaceActivity.coalesceInterval)
        }
    }

    /// The user switched to `workspaceId`: its output is seen, the mark clears.
    /// Repaint-and-reschedule (NOT a bare cancel): the one pending work item
    /// may be ANOTHER workspace's active→unseen decay flip — dropping it
    /// would leave that chip pulsing forever while its tracker sits on
    /// .unseen. refreshWorkspaceActivity cancels, repaints every chip, and
    /// re-arms the earliest remaining decay.
    func workspaceActivitySeen(_ workspaceId: String) {
        workspaceActivity.recordSwitched(to: workspaceId)
        refreshWorkspaceActivity()
    }

    func workspaceActivityForgotten(_ workspaceId: String) {
        workspaceActivity.removeWorkspace(workspaceId)
    }

    /// Chip states for the bar refresh (and the UI probe).
    func workspaceActivityStates() -> [String: TabActivityState] {
        guard let store = memory?.store else { return [:] }
        let now = ProcessInfo.processInfo.systemUptime
        var states: [String: TabActivityState] = [:]
        for workspace in store.listWorkspaces() {
            let state = workspaceActivity.state(of: workspace.id, at: now)
            if state != .idle { states[workspace.id] = state }
        }
        return states
    }

    func workspaceActivityState(of workspaceId: String) -> TabActivityState {
        workspaceActivity.state(of: workspaceId, at: ProcessInfo.processInfo.systemUptime)
    }

    private func refreshWorkspaceActivity() {
        workspaceActivityWork?.cancel()
        workspaceActivityWork = nil
        refreshWorkspaceChips()
        // One more repaint just past the earliest decay boundary flips a
        // pulsing dot to the persistent unseen ring (same pattern as the
        // per-tab indicator in TerminalWindowController).
        let now = ProcessInfo.processInfo.systemUptime
        if let decayAt = workspaceActivity.nextDecay(after: now) {
            scheduleWorkspaceActivityRefresh(after: decayAt - now + 0.05)
        }
    }

    private func scheduleWorkspaceActivityRefresh(after delay: TimeInterval) {
        guard workspaceActivityWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.workspaceActivityWork = nil
            self?.refreshWorkspaceActivity()
        }
        workspaceActivityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.05), execute: work)
    }

    // MARK: - Quit

    /// Founder confirm-quit stage: ⌘Q with running foreground jobs asks once;
    /// plain shells quit instantly (FR-20 stays lossless either way — the
    /// alert's Quit runs the exact same flushSync path). Guarded off for
    /// --smoke and the UI probe (both terminate via exit(), but never risk a
    /// modal in an automated run), and for willPowerOff (that path only
    /// flushes, it never calls terminate:).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if config.confirmQuit, !smokeMode,
           ProcessInfo.processInfo.environment["MEMTERM_UI_PROBE"] != "1" {
            let jobs = runningForegroundJobCount()
            if jobs > 0 {
                let alert = NSAlert()
                alert.messageText = "Quit memterm?"
                alert.informativeText = jobs == 1
                    ? "1 job is still running — it will be terminated. "
                      + "Your layout and sessions will be remembered."
                    : "\(jobs) jobs are still running — they will be terminated. "
                      + "Your layout and sessions will be remembered."
                alert.addButton(withTitle: "Quit")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    return .terminateCancel
                }
            }
        }
        memory?.flushSync()   // windows still open: the snapshot is the live layout
        isTerminating = true
        return .terminateNow
    }

    /// Panes whose foreground process differs from their shell — the same
    /// kernel-truth reads the 2 s capture poll uses (tcgetpgrp on the pty
    /// master, child pids as fallback), taken fresh at quit time. Hidden
    /// workspaces count: their jobs die with the app too.
    private func runningForegroundJobCount() -> Int {
        var jobs = 0
        for controller in controllers {
            for pane in controller.allPanes() {
                guard let process = pane.process, process.running else { continue }
                let shellPid = process.shellPid
                var fg = ProcessInspector.foregroundPgid(masterFd: process.childfd)
                if fg == shellPid { fg = nil }
                if fg == nil { fg = ProcessInspector.childPids(of: shellPid).first }
                if let pid = fg, pid != shellPid { jobs += 1 }
            }
        }
        return jobs
    }

    @objc private func workspaceWillPowerOff(_ note: Notification) {
        memory?.flushSync()
    }

    // MARK: - Restore

    /// `adoptingFrame` (switch-in-place, FR-59): the FIRST restored window
    /// group takes this frame instead of its journaled one, so switching into
    /// a parked workspace presents where the user is already looking;
    /// additional window groups keep their journaled frames. nil (launch
    /// path) restores journaled frames throughout.
    func restoreWindows(_ windows: [WindowRestore], workspaceId: String,
                        adoptingFrame: NSRect? = nil) {
        var focusHost: WindowHostController?
        for (w, win) in windows.enumerated() {
            guard !win.tabs.isEmpty else { continue }
            let frame = w == 0 ? adoptingFrame ?? parseFrame(win.frame)
                              : parseFrame(win.frame)
            let host = makeHost(frame: frame)
            var focusedInHost = false
            for tab in win.tabs {
                let controller = TerminalWindowController(app: self, workspaceId: workspaceId,
                                                          restoredTab: tab)
                controllers.append(controller)
                let focus = controller.tabId == win.focusedTab
                host.attach(controller, select: focus)
                if focus { focusedInHost = true }
            }
            if fadeInPending { host.window?.alphaValue = 0 }
            host.showWindow(nil)
            if focusedInHost || focusHost == nil { focusHost = host }
        }
        focusHost?.focusWindow()
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


    // MARK: - Window / tab plumbing

    /// Creates and registers a new (empty) window host. The caller attaches
    /// at least one tab before showing it.
    @discardableResult
    func makeHost(frame: NSRect?) -> WindowHostController {
        let host = WindowHostController(app: self, frame: frame)
        hosts.append(host)
        return host
    }

    @discardableResult
    func openNewWindow(in workspaceId: String? = nil) -> TerminalWindowController {
        let controller = TerminalWindowController(app: self,
                                                  workspaceId: workspaceId ?? activeWorkspaceId)
        controllers.append(controller)
        let host = makeHost(frame: nil)
        host.attach(controller, select: true)
        host.showWindow(nil)
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
        return controller
    }

    func controllerClosed(_ controller: TerminalWindowController) {
        controllers.removeAll { $0 === controller }
    }

    /// Registers an externally-constructed tab (probe fixtures — e.g. the
    /// serial consent-gate restore leg builds a TabRestore by hand).
    func registerController(_ controller: TerminalWindowController) {
        controllers.append(controller)
    }

    func hostClosed(_ host: WindowHostController) {
        hosts.removeAll { $0 === host }
        if lastFocusedHost === host { lastFocusedHost = nil }
    }

    func keyHost() -> WindowHostController? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let host = hosts.first(where: { $0.window === window }) {
            return host
        }
        // No key-window info (app not active, or a non-host window is key):
        // the model's own focus notion wins over guessing by workspace.
        if let last = lastFocusedHost, hosts.contains(where: { $0 === last }) {
            return last
        }
        return hosts.first { $0.workspaceId == activeWorkspaceId } ?? hosts.first
    }

    func keyController() -> TerminalWindowController? {
        keyHost()?.selectedTab ?? controllers.first
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
        let host = makeHost(frame: nil)
        host.attach(controller, select: true)
        host.showWindow(nil)
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
    }

    /// Standard tab mechanism: ⌘T and the strip's "+" both land here. The new
    /// tab joins the key host and its workspace (FR-49).
    @objc func newWindowForTab(_ sender: Any?) {
        let host = keyHost()
        let controller = TerminalWindowController(
            app: self, workspaceId: host?.workspaceId ?? activeWorkspaceId,
            initialCwd: inheritedCwd())
        controllers.append(controller)
        if let host {
            host.attach(controller, select: true)
        } else {
            let fresh = makeHost(frame: nil)
            fresh.attach(controller, select: true)
            fresh.showWindow(nil)
        }
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
    }

    @objc func renameTab(_ sender: Any?) {
        keyController()?.promptRenameTab()
    }

    // FR-52 next/previous tab (⌘⇧[ / ⌘⇧] + hidden ⌃Tab aliases): host
    // actions replace the NSWindow.selectNextTab/selectPreviousTab native
    // selectors — plain windows have no native tab group to cycle.
    @objc func selectNextTabAction(_ sender: Any?) {
        keyHost()?.selectNextTab()
    }

    @objc func selectPreviousTabAction(_ sender: Any?) {
        keyHost()?.selectPreviousTab()
    }

    /// OUR Move Tab to New Window: re-homes the selected TabController to a
    /// fresh host (same panes, same processes — nothing respawns).
    @objc func moveTabToNewWindowAction(_ sender: Any?) {
        guard let host = keyHost(), host.tabs.count > 1,
              let tab = host.selectedTab else { return }
        let frame = host.window?.frame.offsetBy(dx: 28, dy: -28)
        host.detach(tab)
        let fresh = makeHost(frame: frame)
        fresh.attach(tab, select: true)
        fresh.showWindow(nil)
        fresh.focusWindow()
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
    }

    /// OUR Merge All Windows: folds the active workspace's other hosts' tabs
    /// into the key host (emptied hosts close their windows; no teardown —
    /// the tabs just moved).
    @objc func mergeAllWindowsAction(_ sender: Any?) {
        guard let target = keyHost() else { return }
        for host in hosts where host !== target
            && host.workspaceId == target.workspaceId {
            for tab in host.tabs {
                host.detach(tab)
                target.attach(tab, select: false)
            }
        }
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
        }
        // Chrome rows (workspace bar / tab strip visibility) + window-level
        // theme are per host now.
        for host in hosts { host.applyConfig(config) }
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

    /// ⌘0 Actual Size (council #6): back to the CONFIGURED size — the same
    /// home applyConfigLive resets to when Settings changes the font.
    @objc func resetFontSize(_ sender: Any?) {
        fontSize = CGFloat(config.fontSize)
        let font = currentFont()
        for controller in controllers { controller.applyFont(font) }
    }

    /// ⌘E (council #6): the pane's current selection becomes the find term —
    /// silently, macOS-style (⌘F/⌘G pick it up; a visible bar re-runs live).
    @objc func useSelectionForFind(_ sender: Any?) {
        keyController()?.currentPane()?.useSelectionForFind()
    }

    /// Help ▸ memterm README — bundled into Contents/Resources by make-app.sh.
    @objc func openReadme(_ sender: Any?) {
        if let url = Bundle.main.url(forResource: "README", withExtension: "md") {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()  // unbundled dev binary: no README resource
        }
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
        let historyDir = memory!.historyDir
        let archiveDir = memory!.archiveDir
        memory?.shutdown()  // timers off, writer queue drained
        memory = nil        // releases the engine → StateStore deinit closes the db
        // Founder-amended FR-56: Forget Everything is TRUE deletion of the
        // ARCHIVE too — an empty archive, not an emptied-live-tables one.
        StateStore.purgeAll(dbURL: dbURL, scrollbackDir: scrollbackDir,
                            historyDir: historyDir, archiveDir: archiveDir)

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
        extensionRuntime?.emit(.archiveChanged)  // the archive is empty now
    }

    /// ⌘R: types the captured resume command into the pty WITHOUT a newline —
    /// the user must press Enter themselves (FR-29, no exceptions). For a
    /// serial pane the same gesture performs the reconnect ACTION instead:
    /// no command is composed or typed (consent story: the gesture is the
    /// consent; the denylist path is never involved).
    @objc func typeResumeCommand(_ sender: Any?) {
        guard let pane = keyController()?.currentPane() else { return }
        if let serial = pane as? SerialPaneView, !serial.isConnected {
            serial.performReconnectGesture()
            return
        }
        guard let command = pane.pendingResumeCommand else { return }
        pane.send(txt: command)
        pane.pendingResumeCommand = nil
    }

    // MARK: - Serial (feature/serial UX)

    /// Shell ▸ New Serial Connection… (⌘⇧K — verified unclaimed in MainMenu).
    @objc func newSerialConnection(_ sender: Any?) {
        guard let window = keyController()?.window else { return }
        ensureSerialHotplug()
        let sheet = SerialConnectSheetController(app: self)
        sheet.onConnect = { [weak self] setup in self?.openSerialTab(setup: setup) }
        serialSheet = sheet
        sheet.present(on: window)
    }

    func serialSheetClosed(_ sheet: SerialConnectSheetController) {
        if serialSheet === sheet { serialSheet = nil }
    }

    /// Opens a new tab whose root pane is a serial pane (joins the key host,
    /// like ⌘T). The Connect click that got us here is the consent gesture —
    /// the controller opens the device immediately.
    @discardableResult
    func openSerialTab(setup: SerialPaneView.Setup) -> TerminalWindowController {
        let host = keyHost()
        let controller = TerminalWindowController(
            app: self, workspaceId: host?.workspaceId ?? activeWorkspaceId,
            initialSerial: setup)
        controllers.append(controller)
        if let host {
            host.attach(controller, select: true)
        } else {
            let fresh = makeHost(frame: nil)
            fresh.attach(controller, select: true)
            fresh.showWindow(nil)
        }
        memory?.scheduleTopologySave()
        refreshWorkspaceChips()
        return controller
    }

    /// View ▸ Hex View (⌘⇧X) — the per-pane hex lens; serial panes only.
    @objc func toggleHexView(_ sender: Any?) {
        guard let serial = keyController()?.currentPane() as? SerialPaneView else {
            NSSound.beep()
            return
        }
        serial.setHexMode(!serial.hexMode)
    }

    /// Starts the app-wide hotplug watcher once. Registry watching only —
    /// devices are never opened from here.
    func ensureSerialHotplug() {
        guard serialHotplug == nil else { return }
        let watcher = SerialHotplugWatcher()
        watcher.onAttach = { [weak self] ports in self?.serialPortsChanged(attached: ports) }
        watcher.onDetach = { [weak self] ports in self?.serialPortsChanged(detached: ports) }
        _ = watcher.start()
        serialHotplug = watcher
    }

    private func serialPortsChanged(attached: [SerialPortInfo] = [],
                                    detached: [SerialPortInfo] = []) {
        for controller in controllers {
            for pane in controller.allPanes() {
                guard let serial = pane as? SerialPaneView else { continue }
                if !detached.isEmpty { serial.hotplugDetached(detached) }
                if !attached.isEmpty { serial.hotplugAttached(attached) }
            }
        }
        serialSheet?.reloadPorts()
    }
}

// MARK: - FR-59 supporting types

/// One journal "window": a host's ordered tab controllers plus its focused
/// (selected) tab — first-class model state under custom chrome, read the
/// same way whether the host is visible or a hidden holder.
struct CaptureGroup {
    let members: [TerminalWindowController]
    let focusedTabId: String?
}
