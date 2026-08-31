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
    private let smokeMode: Bool
    /// FR-36/§9: offer-time registry ensuring one `--resume <uuid>` per UUID
    /// across every restore path (launch, workspace switch, unpark).
    let claudeClaims = ClaudeSessionClaims()

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

        // Custom-tab-chrome stage: the tab strip is OURS now — double-click
        // rename, right-click menus, hover ✕, and drag reorder are handled by
        // TabStripView/TabItemView directly. The two NSEvent local monitors
        // (and their tab-strip band geometry) that reverse-engineered the
        // private native tab bar are gone.

        NSApp.activate(ignoringOtherApps: true)
        if smokeMode { runSmoke(restoredAnything: restoredAnything) }
        // MEMTERM_UI_PROBE=1: geometry self-check for the titlebar surfaces
        // (workspace bar under the tab strip, tab accessory) — the headless
        // stand-in for eyeballing when no screen capture is available.
        if ProcessInfo.processInfo.environment["MEMTERM_UI_PROBE"] == "1" { runUIProbe() }
    }

    private func runUIProbe() {
        // Single-tab leg: before the second tab exists, OUR tab strip row
        // must already be visible (its height non-empty), or double-click
        // rename / right-click menu are unreachable on a fresh window. Stage
        // 2: the strip is ALWAYS visible (always_show_tab_bar is a parsed
        // no-op now), so this leg is unconditional.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let host = self.keyHost(), host.window != nil else {
                print("UIPROBE-FAIL no window (single-tab leg)"); exit(1)
            }
            let visible = host.isTabStripVisible
            let regionHeight = host.tabStripFrameInWindow()?.height ?? 0
            print("UIPROBE-SINGLE tab_bar_visible=\(visible) strip_region_h=\(Int(regionHeight))")
            if !visible || regionHeight <= 0 {
                print("UIPROBE-FAIL single-tab tab strip not reachable"); exit(1)
            }
        }
        var probeWorkspaceId: String?
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.newWindowForTab(nil)  // second tab in the same host
            probeWorkspaceId = self.createWorkspace(named: "Probe")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard let host = self.keyHost(), let window = host.window else {
                print("UIPROBE-FAIL no window"); exit(1)
            }
            let bar = host.workspaceBar
            let barFrame = host.workspaceBarFrameInWindow() ?? .zero
            let stripFrame = host.tabStripFrameInWindow() ?? .zero
            print("UIPROBE window_h=\(Int(window.frame.height)) strip_frame_minY=\(Int(stripFrame.minY))")
            print("UIPROBE bar_frame=\(Int(barFrame.minX)),\(Int(barFrame.minY)),\(Int(barFrame.width)),\(Int(barFrame.height)) in_window=\(bar?.window === window)")
            print("UIPROBE tabs_in_strip=\(host.tabStrip.probeTabIds().count) strip_visible=\(host.isTabStripVisible)")
            print("UIPROBE chips=\(bar?.chipTitlesForProbe() ?? [])")
            if host.tabStrip.probeTabIds().count != 2 || !host.isTabStripVisible {
                print("UIPROBE-FAIL both tabs must render in the strip"); exit(1)
            }
            // Founder: "workspaces should be on top then tabs below it" — the
            // workspace row must sit fully ABOVE the tab strip row, and the
            // two rows must not overlap.
            if self.config.workspaceBar {
                print("UIPROBE bar_above_strip=\(barFrame.minY >= stripFrame.maxY - 1)")
                if bar?.window !== window || barFrame.height < 20 {
                    print("UIPROBE-FAIL workspace bar not installed in the chrome"); exit(1)
                }
                if barFrame.minY < stripFrame.maxY - 1 {
                    print("UIPROBE-FAIL workspace bar is not above the tab strip"); exit(1)
                }
            }
            // Strip hit-test leg (replaces the old monitor-band leg — same
            // meaning: rename/menu gestures target tab bodies and ONLY tab
            // bodies): the first tab's center hits that tab, background past
            // the last tab hits nothing, and the workspace bar row is
            // disjoint from the strip row.
            let strip = host.tabStrip!
            guard let firstId = strip.probeTabIds().first,
                  let firstFrame = strip.probeItemFrame(of: firstId) else {
                print("UIPROBE-FAIL no strip items to hit-test"); exit(1)
            }
            let tabHit = strip.probeTabId(atContentX: firstFrame.midX) == firstId
            let backgroundHit = strip.probeTabId(atContentX: 10_000) != nil
            let rowsDisjoint = !self.config.workspaceBar
                || !barFrame.intersects(stripFrame)
            print("UIPROBE-STRIP tab_hit=\(tabHit) background_hit=\(backgroundHit) rows_disjoint=\(rowsDisjoint)")
            if !tabHit || backgroundHit || !rowsDisjoint {
                print("UIPROBE-FAIL strip hit-testing targets the wrong regions"); exit(1)
            }
            // Full-tab tint leg (founder's ask, twice): the SELECTED tab
            // tinted yellow must flip its label to dark text; blue to light.
            guard let selected = host.selectedTab else {
                print("UIPROBE-FAIL no selected tab (tint leg)"); exit(1)
            }
            selected.tabColor = "#febc2e"
            let yellowDark = strip.probeLabelColor(of: selected.tabId) == NSColor.black
            // WHOLE-tab tint (the founder's ask, twice): the tab BODY layer's
            // fill must equal the set color exactly — not a text attribute.
            let yellowBody = strip.probeBodyColor(of: selected.tabId)
            let yellowWanted = Self.nsColor(hex: "#febc2e").cgColor
            let yellowBodyOK = yellowBody == yellowWanted
            selected.tabColor = "#0a84ff"
            let blueLight = strip.probeLabelColor(of: selected.tabId) == NSColor.white
            let blueBodyOK = strip.probeBodyColor(of: selected.tabId)
                == Self.nsColor(hex: "#0a84ff").cgColor
            selected.tabColor = nil
            print("UIPROBE-TINT yellow_dark_text=\(yellowDark) blue_light_text=\(blueLight) yellow_body=\(yellowBodyOK) blue_body=\(blueBodyOK)")
            if !yellowDark || !blueLight || !yellowBodyOK || !blueBodyOK {
                print("UIPROBE-FAIL full-tab tint (body layer color / contrast flip)"); exit(1)
            }
            // In-strip reorder leg: reordering is model state (host.tabs), the
            // strip mirrors it, and the order PERSISTS to the journal (custom
            // titles mark the tabs so the journal rows are attributable).
            host.tabs[0].customTitle = "R-A"
            host.tabs[1].customTitle = "R-B"
            let before = strip.probeTabIds()
            host.reorderTab(from: 0, to: 1)
            host.reorderCommitted()
            let after = strip.probeTabIds()
            let reordered = after == [before[1], before[0]]
                && host.tabs.map(\.tabId) == after
            self.memory?.flushSync()
            let journalTitles = self.memory?.store
                .loadState(workspaceId: self.activeWorkspaceId)
                .first { $0.tabs.count == 2 }?.tabs.map(\.title) ?? []
            let journaled = journalTitles == ["R-B", "R-A"]
            host.reorderTab(from: 1, to: 0)  // put it back
            host.reorderCommitted()
            host.tabs[0].customTitle = nil
            host.tabs[1].customTitle = nil
            print("UIPROBE-REORDER swapped=\(reordered) journal_order=\(journaled) journal_titles=\(journalTitles)")
            if !reordered || !journaled {
                print("UIPROBE-FAIL strip reorder did not mirror the model / persist to the journal")
                exit(1)
            }
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
            // Selecting the tab in its host (the strip click path) clears it.
            if let first = self.controllers.first { first.host?.select(first) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.8) {
            print("UIPROBE-ACT after_select=\(self.controllers.first.map { $0.activityStateForProbe() } ?? .idle)")
            // Keyboard contract: after a tab switch (host.select), the first
            // responder is a pane OF THE SELECTED TAB — keystrokes land in
            // the visible pane.
            guard let host = self.keyHost(), let tab = host.selectedTab else {
                print("UIPROBE-FAIL no selected tab (focus-after-select)"); exit(1)
            }
            let fr = host.window?.firstResponder as? PaneView
            let focusOK = fr != nil && tab.allPanes().contains { $0 === fr }
            print("UIPROBE-FOCUS after_tab_select=\(focusOK)")
            if !focusOK {
                print("UIPROBE-FAIL keystrokes would not land in the selected tab's pane after tab switch")
                exit(1)
            }
        }
        // Workspace-activity leg (founder: hidden workspaces show output):
        // switch to the Probe workspace (Default's windows hide, shells stay
        // live per FR-59), write to a hidden Default pane → Default's chip
        // must mark active, decay to unseen, and clear on switch-back.
        let defaultId = StateStore.defaultWorkspaceId
        var preSwitchHostIds = Set<ObjectIdentifier>()
        var preSwitchVisibleWindow: NSWindow?
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            guard let probe = probeWorkspaceId else {
                print("UIPROBE-FAIL no Probe workspace"); exit(1)
            }
            self.switchToWorkspace(probe)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.4) {
            guard self.activeWorkspaceId != defaultId,
                  let hidden = self.controllers.first(where: { $0.workspaceId == defaultId })
            else { print("UIPROBE-FAIL default workspace not hidden"); exit(1) }
            hidden.allPanes().first?.send(txt: "echo ws-activity\r")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            let state = self.workspaceActivityState(of: defaultId)
            print("UIPROBE-WSACT after_output=\(state)")
            if state == .idle {
                print("UIPROBE-FAIL hidden workspace output did not mark its chip"); exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.8) {
            let state = self.workspaceActivityState(of: defaultId)
            print("UIPROBE-WSACT after_decay=\(state)")
            if state != .unseen {
                print("UIPROBE-FAIL expected unseen after decay, got \(state)"); exit(1)
            }
            // The rendered chip must agree with the state machine.
            let chip = self.hosts
                .first { $0.workspaceId == self.activeWorkspaceId }?
                .workspaceBar?.chipActivityForProbe(workspaceId: defaultId)
            print("UIPROBE-WSACT chip_state=\(chip.map(String.init(describing:)) ?? "nil")")
            if chip != .unseen {
                print("UIPROBE-FAIL chip does not show the unseen ring"); exit(1)
            }
            // FR-59 swap invariants: record host + visible-window identity so
            // the switch-back can prove no window was created or destroyed
            // and the user keeps looking at the SAME window object.
            preSwitchHostIds = Set(self.hosts.map(ObjectIdentifier.init))
            preSwitchVisibleWindow = self.hosts
                .first { $0.window?.isVisible == true }?.window
            self.switchToWorkspace(defaultId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.2) {
            let state = self.workspaceActivityState(of: defaultId)
            print("UIPROBE-WSACT after_switch=\(state)")
            if state != .idle {
                print("UIPROBE-FAIL switching back must clear the mark"); exit(1)
            }
            // Swap-in-place: the same host set, and the same window object is
            // the visible one (no window created/destroyed on switch).
            let sameHosts = Set(self.hosts.map(ObjectIdentifier.init)) == preSwitchHostIds
            let visibleNow = self.hosts.first { $0.window?.isVisible == true }?.window
            let sameWindow = visibleNow != nil && visibleNow === preSwitchVisibleWindow
            // Keyboard contract across a workspace switch: keystrokes land in
            // the swapped-in workspace's selected pane.
            let host = self.keyHost()
            let fr = host?.window?.firstResponder as? PaneView
            let focusOK = fr != nil
                && host?.selectedTab?.allPanes().contains { $0 === fr } == true
            print("UIPROBE-SWAP same_hosts=\(sameHosts) same_visible_window=\(sameWindow) focus_in_pane=\(focusOK)")
            if !sameHosts || !sameWindow || !focusOK {
                print("UIPROBE-FAIL FR-59 swap must reuse the same hosts/window and land focus in the pane")
                exit(1)
            }
            // Settings 2.0 leg: the sectioned window must construct and load
            // (buildForm + loadValues run in init) — a broken control graph
            // would otherwise only surface on the founder's first ⌘,.
            let settings = SettingsWindowController(app: self)
            print("UIPROBE-SETTINGS built=\(settings.window != nil)")
            if settings.window == nil {
                print("UIPROBE-FAIL settings window did not build"); exit(1)
            }
        }
        // Inline-rename leg (chrome placement): the editor must take focus
        // INSIDE the workspace strip, and committing (focus-loss / Enter both
        // end editing) must hand the first responder back to the pane — the
        // exact contract the titlebar-accessory placement needed. The host is
        // captured per leg (not re-resolved via keyHost) so key-window churn
        // under load can't misdirect the assertions.
        var renameHost: WindowHostController?
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) {
            guard self.config.workspaceBar else {
                print("UIPROBE-RENAME skipped (workspace_bar=false)"); return
            }
            guard let host = self.keyHost() else {
                print("UIPROBE-FAIL no host (rename leg)"); exit(1)
            }
            renameHost = host
            host.beginWorkspaceRename(self.activeWorkspaceId)
            // While editing, the first responder is the field editor.
            let editorFocused = host.window?.firstResponder is NSTextView
            print("UIPROBE-RENAME editor_focused=\(editorFocused)")
            if !editorFocused {
                print("UIPROBE-FAIL rename editor did not take focus"); exit(1)
            }
            host.window?.makeFirstResponder(nil)  // commit via end-editing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.9) {
            guard self.config.workspaceBar else { return }
            let focusBack = renameHost?.window?.firstResponder is PaneView
            print("UIPROBE-RENAME focus_back_to_pane=\(focusBack)")
            if !focusBack {
                print("UIPROBE-RENAME-DEBUG fr=\(String(describing: renameHost?.window?.firstResponder)) window=\(String(describing: renameHost?.window)) isWindow=\(renameHost?.window?.firstResponder === renameHost?.window) selected=\(String(describing: renameHost?.selectedTab?.displayTitle)) pane=\(String(describing: renameHost?.selectedTab?.currentPane()))")
                print("UIPROBE-FAIL rename commit did not hand focus back to the pane")
                exit(1)
            }
        }
        // Esc-cancel leg (the rename contract's other half — the known
        // regression class): type a replacement name, press Esc — the store
        // must keep the old name and the keyboard must return to the pane.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.2) {
            guard self.config.workspaceBar else {
                print("UIPROBE-ESC skipped (workspace_bar=false)"); return
            }
            guard let host = self.keyHost(), let window = host.window else {
                print("UIPROBE-FAIL no host (esc leg)"); exit(1)
            }
            renameHost = host
            host.beginWorkspaceRename(self.activeWorkspaceId)
            guard let editor = window.firstResponder as? NSTextView else {
                print("UIPROBE-FAIL esc leg: editor did not take focus"); exit(1)
            }
            editor.insertText("Garbage-Name",
                              replacementRange: NSRange(location: 0,
                                                        length: (editor.string as NSString).length))
            // Field-editor Esc routes through NSTextField's delegate chain to
            // the chip's control(_:textView:doCommandBy:) — the real key path.
            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.6) {
            guard self.config.workspaceBar else { return }
            let names = self.memory?.store.listWorkspaces().map { $0.name } ?? []
            let cancelled = !names.contains("Garbage-Name")
            let focusBack = renameHost?.window?.firstResponder is PaneView
            print("UIPROBE-ESC cancelled=\(cancelled) focus_back_to_pane=\(focusBack) names=\(names) fr=\(String(describing: renameHost?.window?.firstResponder))")
            if !cancelled || !focusBack {
                print("UIPROBE-FAIL Esc did not cancel the rename cleanly"); exit(1)
            }
        }
        // Fullscreen leg (custom chrome): enter/exit must not wedge the
        // chrome — after the round-trip the window is out of fullscreen and
        // the workspace row is back above the tab strip row.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.9) {
            self.keyHost()?.window?.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.7) {
            guard let window = self.keyHost()?.window else {
                print("UIPROBE-FAIL no window (fullscreen leg)"); exit(1)
            }
            let inFullScreen = window.styleMask.contains(.fullScreen)
            print("UIPROBE-FS entered=\(inFullScreen) frame_h=\(Int(window.frame.height))")
            if !inFullScreen {
                print("UIPROBE-FAIL window did not enter fullscreen"); exit(1)
            }
            window.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.5) {
            guard let host = self.keyHost(), let window = host.window else {
                print("UIPROBE-FAIL no window (fullscreen exit)"); exit(1)
            }
            let stillFullScreen = window.styleMask.contains(.fullScreen)
            let barFrame = host.workspaceBarFrameInWindow() ?? .zero
            let stripFrame = host.tabStripFrameInWindow() ?? .zero
            let barOK = !self.config.workspaceBar
                || (host.workspaceBar?.window === window
                    && barFrame.minY >= stripFrame.maxY - 1)
            print("UIPROBE-FS exited=\(!stillFullScreen) bar_restored=\(barOK)")
            if stillFullScreen || !barOK {
                print("UIPROBE-FAIL fullscreen round-trip wedged the chrome"); exit(1)
            }
        }
        // Close-pane leg (founder bug 2026-08-31: split down, close the bottom
        // pane → the whole tab blanked): reproduce exactly and assert the tab
        // survives with one visible pane and a live shell.
        var closeProbePane: PaneView?
        var closeProbeController: TerminalWindowController?
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.9) {
            guard let controller = self.keyController() else {
                print("UIPROBE-FAIL no controller (close-pane leg)"); exit(1)
            }
            closeProbeController = controller
            let before = controller.allPanes()
            controller.splitCurrentPane(vertical: false)
            let after = controller.allPanes()
            closeProbePane = after.first { pane in !before.contains { $0 === pane } }
            if after.count != before.count + 1 || closeProbePane == nil {
                print("UIPROBE-FAIL split for close-pane leg (before=\(before.count) after=\(after.count))")
                exit(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14.5) {
            guard let controller = closeProbeController, let pane = closeProbePane else {
                print("UIPROBE-FAIL close-pane setup lost"); exit(1)
            }
            let windowBefore = controller.window
            controller.close(pane: pane)
            let panes = controller.allPanes()
            let frame = panes.first?.frame ?? .zero
            let windowAlive = controller.window != nil && controller.window === windowBefore
                && self.controllers.contains { $0 === controller }
            let shellAlive = panes.first?.process.running ?? false
            print("UIPROBE-CLOSEPANE window_alive=\(windowAlive) panes=\(panes.count) frame=\(Int(frame.width))x\(Int(frame.height)) shell_alive=\(shellAlive)")
            if !windowAlive || panes.count != 1 || frame.width < 50 || frame.height < 50 || !shellAlive {
                print("UIPROBE-FAIL close-pane blanked the tab"); exit(1)
            }
        }
        // Serial leg (feature/serial): a pty pair stands in for a device —
        // real /dev/cu.* nodes are NEVER touched from the probe. Covers the
        // full loop: open a serial pane on the slave, loopback RX (master →
        // pane render), TX with the CRLF line-ending transform (pane → master
        // bytes), the hex lens, the journaled 'serial' adapter_state, and the
        // EOF disconnect banner.
        var serialMasterFD: Int32 = -1
        var serialPane: SerialPaneView?
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
            let master = posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
                  let slaveC = ptsname(master),
                  case let slavePath = String(cString: slaveC), !slavePath.isEmpty else {
                print("UIPROBE-FAIL serial leg: pty pair"); exit(1)
            }
            serialMasterFD = master
            // Raw master: no kernel echo/translation between the two ends.
            var t = termios()
            tcgetattr(master, &t)
            cfmakeraw(&t)
            tcsetattr(master, TCSANOW, &t)
            _ = fcntl(master, F_SETFL, O_NONBLOCK)
            let setup = SerialPaneView.Setup(
                path: slavePath, identity: "path:\(slavePath)", label: "probe-pty",
                settings: SerialSettings(), txLineEnding: .crlf, localEcho: false)
            let controller = self.openSerialTab(setup: setup)
            guard let pane = controller.allPanes().first as? SerialPaneView else {
                print("UIPROBE-FAIL serial leg: no serial pane"); exit(1)
            }
            serialPane = pane
            print("UIPROBE-SERIAL connected=\(pane.isConnected) title=\(pane.paneTitle)")
            if !pane.isConnected || !pane.paneTitle.contains("@ 115200") {
                print("UIPROBE-FAIL serial pane did not connect (title=\(pane.paneTitle))")
                exit(1)
            }
            let rx = Array("hello-serial\r\n".utf8)
            _ = rx.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.6) {
            guard let pane = serialPane else { print("UIPROBE-FAIL serial pane lost"); exit(1) }
            let text = pane.scrollbackText(maxLines: 200)
            let rxOK = text.contains("hello-serial")
            print("UIPROBE-SERIAL rx_rendered=\(rxOK)")
            if !rxOK { print("UIPROBE-FAIL serial RX not rendered: \(text.suffix(300))"); exit(1) }
            pane.send(txt: "ping\r")  // keystroke path → send override → fd
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16.1) {
            guard let pane = serialPane else { exit(1) }
            var buf = [UInt8](repeating: 0, count: 512)
            let n = read(serialMasterFD, &buf, buf.count)
            let received = n > 0 ? String(decoding: buf[0..<n], as: UTF8.self) : ""
            // CRLF TX transform: the pane's Enter (CR) must arrive as CRLF.
            let txOK = received.contains("ping\r\n")
            print("UIPROBE-SERIAL tx_bytes=\(n) crlf_transform=\(txOK)")
            if !txOK { print("UIPROBE-FAIL serial TX/line-ending (got: \(received.debugDescription))"); exit(1) }
            // Local echo honored, both ways: echo OFF + raw master (no kernel
            // echo) means the typed "ping" must NOT have rendered; flipping
            // echo ON must render the next keystrokes locally even though the
            // master never echoes a byte back.
            let echoOffOK = !pane.scrollbackText(maxLines: 200).contains("ping")
            print("UIPROBE-SERIAL echo_off_honored=\(echoOffOK)")
            if !echoOffOK { print("UIPROBE-FAIL local-echo-off keystrokes rendered"); exit(1) }
            pane.updateLocalEcho(true)
            pane.send(txt: "echo-on-test")
            pane.setHexMode(true)
            let bytes: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef,
                                  0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef]
            _ = bytes.withUnsafeBytes { write(serialMasterFD, $0.baseAddress, $0.count) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16.7) {
            guard let pane = serialPane else { exit(1) }
            let text = pane.scrollbackText(maxLines: 200)
            let hexOK = text.contains("de ad be ef") && text.contains("hex view on")
            print("UIPROBE-SERIAL hex_lens=\(hexOK)")
            if !hexOK { print("UIPROBE-FAIL hex lens: \(text.suffix(300))"); exit(1) }
            let echoOnOK = text.contains("echo-on-test")
            print("UIPROBE-SERIAL echo_on_rendered=\(echoOnOK)")
            if !echoOnOK { print("UIPROBE-FAIL local-echo-on keystrokes did not render"); exit(1) }
            // Journal the pane (2 s poll may not have ticked yet): poll + flush.
            self.memory?.pollNow()
            self.memory?.flushSync()
            var journaled = false
            for window in self.memory?.store.loadState() ?? [] {
                for tab in window.tabs {
                    for (_, paneRestore) in tab.panes {
                        if let snap = paneRestore.snapshot, snap.adapter == SerialAdapter.name,
                           snap.adapterState[SerialAdapter.settingsKey] == "115200-8N1",
                           snap.adapterState[SerialAdapter.pathKey]?.isEmpty == false {
                            journaled = true
                        }
                    }
                }
            }
            print("UIPROBE-SERIAL adapter_journaled=\(journaled)")
            if !journaled { print("UIPROBE-FAIL serial adapter_state not journaled"); exit(1) }
            // "Unplug": closing the pty master REVOKES the slave. macOS can
            // swallow the kevent on revoke (probe-verified: no read event
            // ever fires), so the banner arrives via SerialConnection's
            // 0.5 s liveness probe — the assert below waits > 2 ticks.
            _ = Darwin.close(serialMasterFD)
        }
        var restoredSerialController: TerminalWindowController?
        DispatchQueue.main.asyncAfter(deadline: .now() + 18.0) {
            guard let pane = serialPane else { exit(1) }
            let text = pane.scrollbackText(maxLines: 200)
            let bannerOK = text.contains("device disconnected — will reconnect when it returns")
            print("UIPROBE-SERIAL disconnect_banner=\(bannerOK) still_connected=\(pane.isConnected)")
            if !bannerOK || pane.isConnected {
                print("UIPROBE-FAIL serial disconnect handling"); exit(1)
            }
            // Restore-offer leg: drive the EXACT restore path with a journaled
            // serial snapshot for an absent device. The pane must come back
            // NOT connected (never auto-open on restore) with the standard
            // consent-gated offer line.
            let state = SerialAdapter.journalState(
                path: "/dev/cu.memterm-probe-absent", identity: "usb:0000:0000:probe",
                label: "probe-restore", settings: SerialSettings(),
                txLineEnding: .crlf, localEcho: false)
            let snap = SnapshotRow(exe: "", argv: [], adapter: SerialAdapter.name,
                                   adapterState: state)
            let tab = TabRestore(title: "", tree: .pane("probe-serial-restore"),
                                 panes: ["probe-serial-restore":
                                            PaneRestore(cwd: nil, shell: nil, snapshot: snap)])
            let controller = TerminalWindowController(app: self,
                                                      workspaceId: self.activeWorkspaceId,
                                                      restoredTab: tab)
            self.controllers.append(controller)
            let host = self.makeHost(frame: nil)
            host.attach(controller, select: true)
            host.showWindow(nil)
            host.focusWindow()
            restoredSerialController = controller
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 18.4) {
            guard let controller = restoredSerialController,
                  let pane = controller.allPanes().first as? SerialPaneView else {
                print("UIPROBE-FAIL serial restore did not build a serial pane"); exit(1)
            }
            let text = pane.scrollbackText(maxLines: 100)
            let offerOK = text.contains("was connected: memterm-probe-absent @ 115200-8N1 — press ⌘R to reconnect")
            print("UIPROBE-SERIAL restore_offer=\(offerOK) auto_opened=\(pane.isConnected) pending=\(pane.pendingReconnectOffer)")
            if !offerOK || pane.isConnected || !pane.pendingReconnectOffer {
                print("UIPROBE-FAIL serial restore offer (consent gate)"); exit(1)
            }
            // The ⌘R gesture with the device absent: an honest line, no open.
            self.typeResumeCommand(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 18.8) {
            guard let controller = restoredSerialController,
                  let pane = controller.allPanes().first as? SerialPaneView else { exit(1) }
            let text = pane.scrollbackText(maxLines: 100)
            let honestOK = text.contains("device not connected — memterm-probe-absent @ 115200-8N1")
            print("UIPROBE-SERIAL reconnect_absent=\(honestOK) still_closed=\(!pane.isConnected)")
            if !honestOK || pane.isConnected {
                print("UIPROBE-FAIL ⌘R with absent device must report honestly and not open")
                exit(1)
            }
        }
        // Last-tab-close leg (founder pending item, stage 2): closing the
        // LAST tab of a non-Default workspace auto-removes the now-empty
        // workspace (Default persists), and the MRU corollary surfaces the
        // hidden Default instead of stranding the app windowless. Switching
        // to Probe here also exercises the multi-host slot-matched swap
        // (Default holds two hosts by now; the extra one orders out whole).
        DispatchQueue.main.asyncAfter(deadline: .now() + 19.1) {
            guard let probe = probeWorkspaceId else {
                print("UIPROBE-FAIL no Probe workspace (last-tab-close leg)"); exit(1)
            }
            self.switchToWorkspace(probe)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 19.5) {
            guard let probe = probeWorkspaceId,
                  self.activeWorkspaceId == probe,
                  let listed = self.memory?.store.listWorkspaces()
                      .contains(where: { $0.id == probe }), listed,
                  let doomed = self.controllers.first(where: { $0.workspaceId == probe })
            else {
                print("UIPROBE-FAIL Probe workspace not presented for last-tab close")
                exit(1)
            }
            doomed.close()  // user close of the workspace's only tab
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.1) {
            guard let probe = probeWorkspaceId, let store = self.memory?.store else { exit(1) }
            let names = store.listWorkspaces().map { $0.name }
            let probeGone = !store.listWorkspaces().contains { $0.id == probe }
            let defaultKept = store.listWorkspaces()
                .contains { $0.id == StateStore.defaultWorkspaceId }
            let surfacedDefault = self.activeWorkspaceId == StateStore.defaultWorkspaceId
            let visibleWindow = self.hosts.contains { $0.window?.isVisible == true }
            print("UIPROBE-WSCLOSE probe_removed=\(probeGone) default_kept=\(defaultKept) surfaced_default=\(surfacedDefault) visible_window=\(visibleWindow) names=\(names)")
            if !probeGone || !defaultKept || !surfacedDefault || !visibleWindow {
                print("UIPROBE-FAIL last-tab close must remove the empty workspace and surface Default")
                exit(1)
            }
        }
        // Hover-✕ leg (founder ask): the strip's ✕ closes the tab through the
        // real button action, which is a USER close — FR-56 forgets its rows
        // at the moment of the gesture (before any debounced topology save
        // could) — and focus lands in the surviving selected tab's pane.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.6) {
            guard let host = self.keyHost() else {
                print("UIPROBE-FAIL no host (close-x leg)"); exit(1)
            }
            self.newWindowForTab(nil)
            guard let doomed = host.selectedTab else {
                print("UIPROBE-FAIL close-x leg: no new tab"); exit(1)
            }
            self.memory?.flushSync()
            let beforeTabs = self.memory?.store.counts().tabs ?? -1
            let clicked = host.tabStrip.probeClickClose(of: doomed.tabId)
            self.memory?.store.barrier()
            let afterTabs = self.memory?.store.counts().tabs ?? -1
            let forgotten = afterTabs == beforeTabs - 1
            let gone = !self.controllers.contains { $0 === doomed }
            let stripGone = !host.tabStrip.probeTabIds().contains(doomed.tabId)
            let fr = host.window?.firstResponder as? PaneView
            let focusOK = fr != nil
                && host.selectedTab?.allPanes().contains { $0 === fr } == true
            print("UIPROBE-CLOSEX clicked=\(clicked) rows_forgotten=\(forgotten) controller_gone=\(gone) strip_gone=\(stripGone) focus_in_pane=\(focusOK)")
            if !clicked || !forgotten || !gone || !stripGone || !focusOK {
                print("UIPROBE-FAIL hover ✕ must close, forget (FR-56), and return focus to a pane")
                exit(1)
            }
        }
        // Strip double-click-rename leg (founder ask): the double-click
        // gesture on a tab body opens the rename sheet; committing through
        // the sheet's own Rename button pins the title and journals it.
        var renamedTab: TerminalWindowController?
        DispatchQueue.main.asyncAfter(deadline: .now() + 21.0) {
            guard let host = self.keyHost(), let window = host.window,
                  let tab = host.selectedTab else {
                print("UIPROBE-FAIL no host (rename-tab leg)"); exit(1)
            }
            renamedTab = tab
            let doubled = host.tabStrip.probeDoubleClickTab(tab.tabId)
            guard doubled, let sheet = window.attachedSheet,
                  let sheetRoot = sheet.contentView else {
                print("UIPROBE-FAIL double-click on the tab did not open the rename sheet")
                exit(1)
            }
            func findField(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                for sub in view.subviews { if let f = findField(sub) { return f } }
                return nil
            }
            func findButton(_ view: NSView, title: String) -> NSButton? {
                if let button = view as? NSButton, button.title == title { return button }
                for sub in view.subviews {
                    if let b = findButton(sub, title: title) { return b }
                }
                return nil
            }
            guard let field = findField(sheetRoot),
                  let rename = findButton(sheetRoot, title: "Rename") else {
                print("UIPROBE-FAIL rename sheet lacks its field/button"); exit(1)
            }
            field.stringValue = "Probe-Renamed"
            rename.performClick(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 21.4) {
            guard let tab = renamedTab else { exit(1) }
            let titleOK = tab.displayTitle == "Probe-Renamed"
            self.memory?.flushSync()
            let journaled = self.memory?.store
                .loadState(workspaceId: self.activeWorkspaceId)
                .flatMap(\.tabs).contains { $0.title == "Probe-Renamed" } ?? false
            print("UIPROBE-RENAMETAB title=\(titleOK) journaled=\(journaled) display=\(tab.displayTitle)")
            if !titleOK || !journaled {
                print("UIPROBE-FAIL strip double-click rename did not pin/journal the title")
                exit(1)
            }
            tab.customTitle = nil
        }
        // Move Tab to New Window / Merge All Windows leg: OUR re-homing —
        // same pane objects, same shell process, one extra host; merge folds
        // the workspace back into one host with identity intact.
        DispatchQueue.main.asyncAfter(deadline: .now() + 21.8) {
            // The active workspace holds several hosts by now; act on the
            // multi-tab one (moveTabToNewWindow needs a tab to leave behind).
            guard let host = self.hosts.first(where: { h in
                      h.workspaceId == self.activeWorkspaceId && h.tabs.count > 1
                          && h.tabs.contains {
                              $0.allPanes().first?.process?.running == true
                          }
                  }),
                  let tab = host.tabs.first(where: {
                      $0.allPanes().first?.process?.running == true
                  }) else {
                print("UIPROBE-FAIL no multi-tab host with a shell tab (move-window leg)")
                exit(1)
            }
            host.focusWindow()
            host.select(tab)
            let paneIds = Set(tab.allPanes().map(ObjectIdentifier.init))
            guard let pid = tab.allPanes().first?.process?.shellPid else {
                print("UIPROBE-FAIL move-window leg: no shell pid"); exit(1)
            }
            let hostsBefore = self.hosts.count
            self.moveTabToNewWindowAction(nil)
            let fresh = tab.host
            let moved = fresh !== host && self.hosts.count == hostsBefore + 1
                && fresh?.tabs.count == 1
            let samePanesMoved = Set(tab.allPanes().map(ObjectIdentifier.init)) == paneIds
            self.mergeAllWindowsAction(nil)
            let mergedHosts = self.hosts.filter {
                $0.workspaceId == self.activeWorkspaceId
            }
            let merged = mergedHosts.count == 1
                && (mergedHosts.first?.tabs.count ?? 0) >= 2
            let samePanes = samePanesMoved
                && Set(tab.allPanes().map(ObjectIdentifier.init)) == paneIds
            let alive = kill(pid, 0) == 0
            print("UIPROBE-MOVEWIN moved=\(moved) merged=\(merged) same_panes=\(samePanes) pid_alive=\(alive)")
            if !moved || !merged || !samePanes || !alive {
                print("UIPROBE-FAIL move-to-new-window/merge must re-home the same panes with the process untouched")
                exit(1)
            }
            exit(0)
        }
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
            var defaultPaneIds = Set<ObjectIdentifier>()
            var defaultPids: [pid_t] = []
            var defaultFrame = NSRect.zero
            func defaultControllers() -> [TerminalWindowController] {
                self.controllers.filter { $0.workspaceId == StateStore.defaultWorkspaceId }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                self.memory?.flushSync()
                guard let counts = self.memory?.store.counts() else { exit(1) }
                print("SMOKE-SAVED windows=\(counts.windows) tabs=\(counts.tabs) panes=\(counts.panes)")
                // Per-tab shell history leg: the pane that ran 'cd /tmp' runs
                // the REAL zsh integration (real rc files, real hooks) — its
                // .hist file must exist and contain the command. Non-zsh
                // shells (or integration off) skip with a note, never fail.
                if let pane = self.controllers.first?.allPanes().first,
                   let engine = self.memory {
                    let shellPath = pane.shellPath ?? ""
                    if self.config.shellIntegration,
                       ShellIntegration.isZsh(shellPath: shellPath),
                       engine.shellIntegrationDir != nil {
                        let histURL = ShellIntegration.histFileURL(
                            dir: engine.historyDir, paneId: pane.paneId)
                        let hist = (try? String(contentsOf: histURL, encoding: .utf8)) ?? ""
                        if hist.contains("cd /tmp") {
                            print("SMOKE-HIST captured=true entries=\(hist.split(separator: "\n").count)")
                        } else {
                            print("SMOKE-FAIL pane history missing 'cd /tmp' at \(histURL.path) (contents: \(hist.prefix(200)))")
                            exit(1)
                        }
                    } else {
                        print("SMOKE-HIST skipped (shell \(shellPath) is not zsh or integration off)")
                    }
                }
                // FR-59 leg: record Default's controllers, shell pids, and
                // frame, then switch to a fresh workspace B (resurrect/fresh
                // path: B has no live tabs, so Default's hosts hide whole).
                // Default's tabs must stay LIVE — same objects, processes
                // untouched, no host displaying them.
                let defaults = defaultControllers()
                defaultControllerIds = Set(defaults.map(ObjectIdentifier.init))
                let panes = defaults.flatMap { $0.allPanes() }
                defaultPaneIds = Set(panes.map(ObjectIdentifier.init))
                defaultPids = panes.compactMap { $0.process?.shellPid }
                defaultFrame = defaults.first?.window?.frame ?? .zero
                // The leg is only meaningful against the full 2-tab/3-pane
                // build-out: every pane must have a live shell pid recorded.
                guard defaults.count == 2, panes.count == 3,
                      defaultPids.count == 3 else {
                    print("SMOKE-FAIL live-switch precondition: tabs=\(defaults.count) panes=\(panes.count) pids=\(defaultPids.count)")
                    exit(1)
                }
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
                // Switch back: the FR-59 tab-set swap (Default has live tabs
                // in a hidden holder), NOT the restore pipeline — Default's
                // tabs swap INTO the window the user is looking at.
                self.switchToWorkspace(StateStore.defaultWorkspaceId)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.1) {
                let defaults = defaultControllers()
                let panes = defaults.flatMap { $0.allPanes() }
                let sameObjects = Set(defaults.map(ObjectIdentifier.init)) == defaultControllerIds
                // Identity on the PANE object graph too, not just controllers:
                // a rebuilt pane tree inside surviving controllers would pass
                // the controller check while silently respawning shells.
                let samePanes = Set(panes.map(ObjectIdentifier.init)) == defaultPaneIds
                let visible = defaults.contains { $0.window?.isVisible == true }
                // kill(pid, 0) on the ORIGINAL pre-switch pids, post round-trip.
                let survivors = defaultPids.filter { kill($0, 0) == 0 }.count
                let dividers = panes.reduce(0) { $0 + $1.restoredDividerCount }
                // Frame stability under the swap model: the window now
                // DISPLAYING Default is the one the user was looking at
                // throughout, whose frame was adopted from Default's original
                // window at the first switch — byte-identical frames.
                let framesStable = defaults.first?.window?.frame == defaultFrame
                guard sameObjects, samePanes, visible, survivors == defaultPids.count,
                      !defaultPids.isEmpty, dividers == 0, framesStable else {
                    print("SMOKE-FAIL live-switch show: sameObjects=\(sameObjects) samePanes=\(samePanes) visible=\(visible) pids=\(survivors)/\(defaultPids.count) dividers=\(dividers) framesStable=\(framesStable) before=\(defaultFrame) after=\(String(describing: defaults.first?.window?.frame))")
                    exit(1)
                }
                print("SMOKE-LIVE-SWITCH pids_survived=\(survivors) same_panes=\(samePanes) frames_stable=\(framesStable)")
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
                let windows = self.hosts.filter { !$0.tabs.isEmpty }.count
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
        memory?.shutdown()  // timers off, writer queue drained
        memory = nil        // releases the engine → StateStore deinit closes the db
        StateStore.purgeAll(dbURL: dbURL, scrollbackDir: scrollbackDir,
                            historyDir: historyDir)

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
