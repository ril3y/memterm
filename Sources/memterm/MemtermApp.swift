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
        // Single-tab leg (always_show_tab_bar): before the second tab exists,
        // the tab bar must already be visible and the monitors' tab-strip
        // region (tabStripBottomY .. frame.height-28) must be non-empty, or
        // double-click rename / right-click menu are unreachable on a fresh
        // window. Skipped when the founder's config disables the policy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard self.config.alwaysShowTabBar else {
                print("UIPROBE-SINGLE skipped (always_show_tab_bar=false)")
                return
            }
            guard let controller = self.keyController(), let window = controller.window else {
                print("UIPROBE-FAIL no window (single-tab leg)"); exit(1)
            }
            let visible = window.tabGroup?.isTabBarVisible == true
            let regionHeight = window.frame.height - 28 - controller.tabStripBottomY()
            print("UIPROBE-SINGLE tab_bar_visible=\(visible) strip_region_h=\(Int(regionHeight))")
            if !visible || regionHeight <= 0 {
                print("UIPROBE-FAIL single-tab tab bar not reachable"); exit(1)
            }
        }
        var probeWorkspaceId: String?
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.newWindowForTab(nil)  // second tab so the tab bar is visible
            probeWorkspaceId = self.createWorkspace(named: "Probe")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard let controller = self.keyController(), let window = controller.window else {
                print("UIPROBE-FAIL no window"); exit(1)
            }
            let bar = controller.workspaceBar
            let barFrame = controller.workspaceBarFrameInWindow() ?? .zero
            let content = window.contentLayoutRect
            print("UIPROBE window_h=\(Int(window.frame.height)) content_maxY=\(Int(content.maxY))")
            print("UIPROBE bar_frame=\(Int(barFrame.minX)),\(Int(barFrame.minY)),\(Int(barFrame.width)),\(Int(barFrame.height)) in_window=\(bar?.window === window)")
            print("UIPROBE tabstrip_bottom=\(Int(controller.tabStripBottomY())) tab_bar_visible=\(window.tabGroup?.isTabBarVisible == true)")
            print("UIPROBE chips=\(bar?.chipTitlesForProbe() ?? []) accessory_set=\(window.tab.accessoryView != nil)")
            // Founder: "workspaces should be on top then tabs below it" — the
            // bar (a .top titlebar accessory) must sit fully ABOVE the tab
            // strip, whose band is [tabStripBottomY, minY of the bar]: assert
            // the bar's bottom clears the strip's bottom edge by at least the
            // strip's own plausible height (i.e. bar.minY > content top), and
            // that the terminal content starts below ALL chrome.
            if self.config.workspaceBar {
                let stripBottom = controller.tabStripBottomY()
                print("UIPROBE bar_above_strip=\(barFrame.minY > stripBottom)")
                if bar?.window !== window || barFrame.height < 20 {
                    print("UIPROBE-FAIL workspace bar not installed in the titlebar"); exit(1)
                }
                if barFrame.minY <= stripBottom {
                    print("UIPROBE-FAIL workspace bar is not above the tab strip"); exit(1)
                }
            }
            // Monitor-band leg: the double-click-rename and right-click-menu
            // monitors must target the tab strip band and ONLY it. Synthesize
            // the events the monitors would receive and run them through the
            // shared region check: mid-strip hits, terminal content misses,
            // the bar's interior misses, and the accessory row's side margins
            // (the 4pt sliver beside the bar, under the traffic lights)
            // miss — those are titlebar clicks, not tab-strip gestures.
            func probeEvent(_ x: CGFloat, _ y: CGFloat) -> NSEvent? {
                NSEvent.mouseEvent(with: .leftMouseDown,
                                   location: NSPoint(x: x, y: y),
                                   modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 2,
                                   pressure: 1)
            }
            func hits(_ x: CGFloat, _ y: CGFloat) -> Bool {
                probeEvent(x, y).flatMap { self.tabStripController(for: $0) } != nil
            }
            let stripBottom = controller.tabStripBottomY()
            let bandTop = self.config.workspaceBar && barFrame.height > 0
                ? barFrame.minY : window.frame.height - 28
            let stripHit = hits(window.frame.width / 2, (stripBottom + bandTop) / 2)
            let contentHit = hits(window.frame.width / 2, stripBottom - 30)
            var barHit = false, sliverHit = false
            if self.config.workspaceBar, barFrame.height > 0 {
                barHit = hits(barFrame.midX, barFrame.midY)
                sliverHit = hits(barFrame.minX - 10, barFrame.minY + 2)
            }
            print("UIPROBE-BAND strip=\(stripHit) content=\(contentHit) bar=\(barHit) titlebar_sliver=\(sliverHit)")
            if !stripHit || contentHit || barHit || sliverHit {
                print("UIPROBE-FAIL tab-strip monitors target the wrong band"); exit(1)
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
            self.controllers.first?.window?.makeKeyAndOrderFront(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.8) {
            print("UIPROBE-ACT after_select=\(self.controllers.first.map { $0.activityStateForProbe() } ?? .idle)")
        }
        // Workspace-activity leg (founder: hidden workspaces show output):
        // switch to the Probe workspace (Default's windows hide, shells stay
        // live per FR-59), write to a hidden Default pane → Default's chip
        // must mark active, decay to unseen, and clear on switch-back.
        let defaultId = StateStore.defaultWorkspaceId
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
            let chip = self.controllers
                .first { $0.workspaceId == self.activeWorkspaceId }?
                .workspaceBar?.chipActivityForProbe(workspaceId: defaultId)
            print("UIPROBE-WSACT chip_state=\(chip.map(String.init(describing:)) ?? "nil")")
            if chip != .unseen {
                print("UIPROBE-FAIL chip does not show the unseen ring"); exit(1)
            }
            self.switchToWorkspace(defaultId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.2) {
            let state = self.workspaceActivityState(of: defaultId)
            print("UIPROBE-WSACT after_switch=\(state)")
            if state != .idle {
                print("UIPROBE-FAIL switching back must clear the mark"); exit(1)
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
        // Inline-rename leg (.top accessory placement): the editor must take
        // focus INSIDE the titlebar accessory, and committing (focus-loss /
        // Enter both end editing) must hand the first responder back to the
        // pane — the exact gate the content-view placement needed. The
        // controller is captured per leg (not re-resolved via keyController)
        // so key-window churn under load can't misdirect the assertions.
        var renameController: TerminalWindowController?
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.5) {
            guard self.config.workspaceBar else {
                print("UIPROBE-RENAME skipped (workspace_bar=false)"); return
            }
            guard let controller = self.keyController() else {
                print("UIPROBE-FAIL no controller (rename leg)"); exit(1)
            }
            renameController = controller
            controller.beginWorkspaceRename(self.activeWorkspaceId)
            // While editing, the first responder is the field editor.
            let editorFocused = controller.window?.firstResponder is NSTextView
            print("UIPROBE-RENAME editor_focused=\(editorFocused)")
            if !editorFocused {
                print("UIPROBE-FAIL rename editor did not take focus"); exit(1)
            }
            controller.window?.makeFirstResponder(nil)  // commit via end-editing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.9) {
            guard self.config.workspaceBar else { return }
            let focusBack = renameController?.window?.firstResponder is PaneView
            print("UIPROBE-RENAME focus_back_to_pane=\(focusBack)")
            if !focusBack {
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
            guard let controller = self.keyController(), let window = controller.window else {
                print("UIPROBE-FAIL no controller (esc leg)"); exit(1)
            }
            renameController = controller
            controller.beginWorkspaceRename(self.activeWorkspaceId)
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
            let focusBack = renameController?.window?.firstResponder is PaneView
            print("UIPROBE-ESC cancelled=\(cancelled) focus_back_to_pane=\(focusBack) names=\(names) fr=\(String(describing: renameController?.window?.firstResponder))")
            if !cancelled || !focusBack {
                print("UIPROBE-FAIL Esc did not cancel the rename cleanly"); exit(1)
            }
        }
        // Fullscreen leg (.top accessory placement): enter/exit must not wedge
        // the accessory — after the round-trip the window is out of
        // fullscreen, the terminal content spans the restored layout area,
        // and the bar is back in the titlebar above the tab strip.
        DispatchQueue.main.asyncAfter(deadline: .now() + 9.9) {
            self.keyController()?.window?.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.7) {
            guard let window = self.keyController()?.window else {
                print("UIPROBE-FAIL no window (fullscreen leg)"); exit(1)
            }
            let inFullScreen = window.styleMask.contains(.fullScreen)
            print("UIPROBE-FS entered=\(inFullScreen) content_maxY=\(Int(window.contentLayoutRect.maxY)) frame_h=\(Int(window.frame.height))")
            if !inFullScreen {
                print("UIPROBE-FAIL window did not enter fullscreen"); exit(1)
            }
            window.toggleFullScreen(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.5) {
            guard let controller = self.keyController(), let window = controller.window else {
                print("UIPROBE-FAIL no window (fullscreen exit)"); exit(1)
            }
            let stillFullScreen = window.styleMask.contains(.fullScreen)
            let barFrame = controller.workspaceBarFrameInWindow() ?? .zero
            let barOK = !self.config.workspaceBar
                || (controller.workspaceBar?.window === window
                    && barFrame.minY > controller.tabStripBottomY())
            print("UIPROBE-FS exited=\(!stillFullScreen) bar_restored=\(barOK)")
            if stillFullScreen || !barOK {
                print("UIPROBE-FAIL fullscreen round-trip wedged the accessory"); exit(1)
            }
            exit(0)
        }
    }

    // MARK: - Tab-strip gestures (shared region logic for both monitors)

    /// The tab this gesture applies to, when the event lands on the native
    /// tab strip of one of our windows: between the top of the content layout
    /// area (contentLayoutRect.maxY — the strip's bottom edge under
    /// .fullSizeContentView) and the bottom of the titlebar proper. The
    /// workspace bar is a .top titlebar accessory now, so any point inside
    /// its frame is the BAR's gesture (chip double-click rename, chip
    /// right-click menu), never the tab strip's — excluded explicitly, which
    /// stays correct wherever AppKit places the accessory. Returns the
    /// controller of the window that received the event — the selected tab
    /// of its group.
    private func tabStripController(for event: NSEvent) -> TerminalWindowController? {
        guard let window = event.window,
              window.tabGroup?.isTabBarVisible == true,
              let controller = controllers.first(where: { $0.window === window })
        else { return nil }
        let y = event.locationInWindow.y
        let tabStripBottom = controller.tabStripBottomY()
        // 28 is a heuristic: with .fullSizeContentView the titlebar row
        // measures 32 on macOS 26.2 (probe-verified: chrome is 68pt with and
        // without the bar), so without the bar installed the band overshoots
        // ~4pt into blank titlebar — harmless (double-click there renames
        // instead of zooming), and there is no public API for the row height.
        // With the bar installed, its frame gives the row exactly.
        var bandTop = window.frame.height - 28
        if let barFrame = controller.workspaceBarFrameInWindow() {
            if barFrame.contains(event.locationInWindow) { return nil }
            // With the bar installed, its row IS the topmost titlebar row
            // (traffic lights inset it on the left, the gear on the right),
            // and the tab strip ends where that row begins. The 28pt
            // heuristic alone overshoots ~4pt into the accessory row's side
            // margins (x < traffic-light inset, x > bar trailing edge) —
            // clicks there are titlebar clicks, never tab-strip gestures.
            bandTop = min(bandTop, barFrame.minY)
        }
        guard y >= tabStripBottom, y <= bandTop else { return nil }
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
        var focusTarget: TerminalWindowController?
        for (w, win) in windows.enumerated() {
            var host: TerminalWindowController?
            for (i, tab) in win.tabs.enumerated() {
                let frame = i == 0
                    ? (w == 0 ? adoptingFrame ?? parseFrame(win.frame) : parseFrame(win.frame))
                    : nil
                let controller = TerminalWindowController(app: self, workspaceId: workspaceId,
                                                          restoredTab: tab,
                                                          restoredFrame: frame)
                if fadeInPending { controller.window?.alphaValue = 0 }
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
                // frame, then switch to a fresh workspace B. The switch must
                // HIDE Default — same objects, processes untouched.
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
                // Switch back: hide/show, NOT the restore pipeline.
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
