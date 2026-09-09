import AppKit
import MemtermCore

// Custom-tab-chrome stage (founder-approved rearchitecture, stage 1): one
// NSWindow per window-host. memterm draws ALL tab/workspace chrome itself —
// native NSWindow tabbing is disabled (tabbingMode = .disallowed) and a
// window shows: the workspace strip (row 1, the existing WorkspaceBarView
// re-hosted as a plain subview), our TabStripView (row 2, full-tab tint /
// hover close / activity marks / drag reorder), and below the chrome one
// content container displaying the SELECTED tab's pane tree.
//
// Tabs are TerminalWindowController instances (the TabModel — they no longer
// own windows); selecting a tab swaps its `paneRoot` into the container and
// hands first-responder status to the tab's focused pane. Deselected tabs
// keep their views, panes, ptys, and processes alive while detached — the
// same liveness contract hidden workspaces already had (FR-59).
//
// WINDOW TITLE DECISION (blueprint): titleVisibility = .hidden — titles are
// drawn in the strip — but window.title stays synced to the selected tab's
// title for Mission Control, the Window menu, and accessibility. This deletes
// the old ".top accessory hides the title" caveat outright.
//
// FR-56 in the close paths: every teardown goes through
// TerminalWindowController.teardown(userInitiated:). The traffic-light close
// is a USER close of all the host's tabs (Safari convention — flagged to the
// founder in the blueprint's risk list); quit / park / forget reach
// windowWillClose with the isTerminating / isSwitchingWorkspaces flags set,
// so the per-tab inference resolves those to non-user teardown exactly as the
// old per-tab-window windowWillClose did.

final class WindowHostController: NSWindowController, NSWindowDelegate {
    private unowned let app: MemtermAppDelegate

    private(set) var tabs: [TerminalWindowController] = []
    private(set) var selectedTab: TerminalWindowController?
    /// The workspace this host's tabs belong to (all tabs of a host share
    /// one workspace — ⌘T inherits, moveTab re-homes across hosts).
    var workspaceId: String? { tabs.first?.workspaceId }

    // -- Chrome --
    private let chromeStack = NSStackView()
    private let barRow = NSView()
    /// Chrome row heights follow ChromeMetrics (Appearance › Size); kept so
    /// applyConfig can re-size the rows live.
    private var barRowHeight: NSLayoutConstraint!
    private var tabStripHeight: NSLayoutConstraint!
    private(set) var workspaceBar: WorkspaceBarView?
    private let gearButton = ChipButton()
    private(set) var tabStrip: TabStripView!
    private let contentContainer = TabContentContainerView()
    private let blurView = NSVisualEffectView()
    /// FR-59 in-window crossfade: the outgoing content's snapshot, fading out
    /// over the swapped-in workspace (Workspaces.swapTabSets).
    private var crossfadeOverlay: NSImageView?

    // PINNED DEPENDENCY (moved here from the per-tab controller): the window's
    // firstResponder KVO drives focusedPane tracking. NSWindow.firstResponder
    // is not documented KVO-compliant but works on every macOS to date — if an
    // update stops emitting, currentPane() degrades to its fallbacks; check
    // here first if multi-pane focus targeting regresses after an OS update.
    private var firstResponderObservation: NSKeyValueObservation?

    /// Quake-style drop-down (2026-09-09): a .dropdown host is the active
    /// workspace's slide-in panel — journaled with role "dropdown", restored
    /// hidden, placed by DropdownController, never a swap slot.
    enum Role { case normal, dropdown }
    let role: Role
    var isDropdown: Bool { role == .dropdown }

    init(app: MemtermAppDelegate, frame: NSRect?, role: Role = .normal) {
        self.app = app
        self.role = role
        let rect = NSRect(x: 0, y: 0, width: 980, height: 640)
        // The panel has no traffic lights and is not user-movable: its place
        // is the configured edge, and Esc-style dismissal is the hotkey.
        let styleMask: NSWindow.StyleMask = role == .dropdown
            ? [.titled, .fullSizeContentView]
            : [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // Quiet probe/smoke runs (TESTING.md §2.5) position windows offscreen
        // — ProbeQuietWindow disables AppKit's frame constraining so they
        // stay there.
        let window: NSWindow
        if role == .dropdown {
            // The panel parks fully OFF its screen edge between shows; a
            // plain NSWindow's constrainFrameRect would clamp that back on
            // screen (visible-probe finding, 2026-09-09) and the slide would
            // stop short.
            window = DropdownWindow(contentRect: rect, styleMask: styleMask,
                                    backing: .buffered, defer: false)
        } else if ProbeSupport.quiet {
            window = ProbeQuietWindow(contentRect: rect, styleMask: styleMask,
                                      backing: .buffered, defer: false)
        } else {
            window = NSWindow(contentRect: rect, styleMask: styleMask,
                              backing: .buffered, defer: false)
        }
        window.title = "memterm"
        // Custom chrome: the strip draws titles; native tabbing is OFF.
        window.titleVisibility = .hidden
        // Founder bug 2026-09-01 ("no workspaces bar, looks all the same"):
        // with .fullSizeContentView the titlebar still paints its material
        // OVER the content's top band — exactly where the workspace bar row
        // sits — hiding it on every real launch. Content-view bitmap probes
        // could not see this (they render below the titlebar overlay); only
        // a composited window capture can. Transparent titlebar lets the
        // chrome rows show through; the bar's leadingInset already clears
        // the traffic lights.
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        if role == .dropdown {
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            window.hidesOnDeactivate = false
            window.isExcludedFromWindowsMenu = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
        if let frame {
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }
        if ProbeSupport.quiet {
            window.setFrameOrigin(NSPoint(x: -4000 - window.frame.width,
                                          y: window.frame.origin.y))
        }
        if let bg = app.config.themeBackgroundColor { window.backgroundColor = bg }
        super.init(window: window)
        window.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        window.contentView = content

        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.isHidden = true
        content.addSubview(blurView)

        // Row 1: workspace strip + trailing gear (the old .right accessory).
        let bar = WorkspaceBarView(app: app, leadingInset: Self.trafficLightInset)
        workspaceBar = bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        barRow.addSubview(bar)
        gearButton.configureAsSettingsGear(app: app)
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        barRow.addSubview(gearButton)
        barRow.translatesAutoresizingMaskIntoConstraints = false
        let metrics = app.chromeMetrics
        bar.applyMetrics(metrics)
        barRowHeight = barRow.heightAnchor.constraint(
            equalToConstant: CGFloat(metrics.workspaceBarHeight))
        NSLayoutConstraint.activate([
            barRowHeight,
            bar.leadingAnchor.constraint(equalTo: barRow.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: barRow.trailingAnchor),
            bar.topAnchor.constraint(equalTo: barRow.topAnchor),
            bar.bottomAnchor.constraint(equalTo: barRow.bottomAnchor),
            gearButton.trailingAnchor.constraint(equalTo: barRow.trailingAnchor, constant: -8),
            gearButton.centerYAnchor.constraint(equalTo: barRow.centerYAnchor),
            gearButton.widthAnchor.constraint(equalToConstant: 24),
            gearButton.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Row 2: the tab strip.
        tabStrip = TabStripView(app: app, host: self)
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        tabStripHeight = tabStrip.heightAnchor.constraint(
            equalToConstant: CGFloat(metrics.tabStripHeight))
        tabStripHeight.isActive = true

        chromeStack.orientation = .vertical
        chromeStack.alignment = .leading
        chromeStack.spacing = 0
        chromeStack.distribution = .fill
        chromeStack.translatesAutoresizingMaskIntoConstraints = false
        chromeStack.addArrangedSubview(barRow)
        chromeStack.addArrangedSubview(tabStrip)
        content.addSubview(chromeStack)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(contentContainer)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chromeStack.topAnchor.constraint(equalTo: content.topAnchor),
            chromeStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chromeStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            barRow.widthAnchor.constraint(equalTo: chromeStack.widthAnchor),
            tabStrip.widthAnchor.constraint(equalTo: chromeStack.widthAnchor),
            contentContainer.topAnchor.constraint(equalTo: chromeStack.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            blurView.topAnchor.constraint(equalTo: content.topAnchor),
            blurView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        applyWindowChrome(app.config)
        updateChromeVisibility()

        firstResponderObservation = window.observe(\.firstResponder) { [weak self] window, _ in
            guard let self, let pane = window.firstResponder as? PaneView,
                  let tab = self.tab(containing: pane) else { return }
            tab.paneFocused(pane)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Leading inset that keeps the topmost chrome row's content clear of the
    /// traffic lights (AppKit used to inset titlebar accessories ~78 pt).
    static let trafficLightInset: CGFloat = 78

    /// Deliberate programmatic focus: orders the window key/front AND records
    /// this host as the app's focused host — NSApp.keyWindow can lag or stay
    /// nil entirely when the app is not the active app (probe/smoke runs), so
    /// keyHost() needs the model's own notion kept current.
    func focusWindow() {
        window?.makeKeyAndOrderFront(nil)
        app.noteHostFocused(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        app.noteHostFocused(self)
    }

    // MARK: - Tab management

    func tab(containing pane: PaneView) -> TerminalWindowController? {
        tabs.first { tab in tab.allPanes().contains { $0 === pane } }
    }

    func attach(_ tab: TerminalWindowController, select: Bool) {
        tab.host = self
        tabs.append(tab)
        updateChromeVisibility()
        tabStrip.reload()
        if select || selectedTab == nil {
            self.select(tab)
        }
    }

    /// Re-homing detach (moveTab / Move Tab to New Window): the tab keeps its
    /// panes and processes; only its hosting changes. An emptied host closes
    /// its window (nothing to tear down — the tabs already left).
    func detach(_ tab: TerminalWindowController) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        let index = tabs.firstIndex { $0 === tab } ?? 0
        tabs.removeAll { $0 === tab }
        if selectedTab === tab {
            selectedTab = nil
            tab.paneRoot.removeFromSuperview()
            if !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)]) }
        }
        if tab.host === self { tab.host = nil }
        updateChromeVisibility()
        tabStrip.reload()
        if tabs.isEmpty { window?.close() }
    }

    /// FR-56: the ONE close path for a hosted tab — every gesture and teardown
    /// funnels here with explicit intent (the strip's hover ✕, the context
    /// menu's Close Tab, ⌘W's last pane, park/forget/quit teardown).
    func close(tab: TerminalWindowController, userInitiated: Bool) {
        guard tabs.contains(where: { $0 === tab }) else {
            tab.teardown(userInitiated: userInitiated)
            return
        }
        let index = tabs.firstIndex { $0 === tab } ?? 0
        tabs.removeAll { $0 === tab }
        if selectedTab === tab {
            selectedTab = nil
            tab.paneRoot.removeFromSuperview()
            if !tabs.isEmpty { select(tabs[min(index, tabs.count - 1)]) }
        }
        if tab.host === self { tab.host = nil }
        tab.teardown(userInitiated: userInitiated)
        updateChromeVisibility()
        tabStrip.reload()
        if tabs.isEmpty { window?.close() }
    }

    /// Selects `tab`: swaps its pane tree into the content container, hands
    /// the first responder to the tab's focused pane, and re-syncs titles.
    /// The outgoing tab's views stay alive (retained by their controller)
    /// while detached; the incoming root re-adopts the container's CURRENT
    /// bounds, so panes whose window resized while they were deselected get
    /// their pty size reasserted by the frame change.
    func select(_ tab: TerminalWindowController) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if selectedTab !== tab {
            selectedTab?.paneRoot.removeFromSuperview()
            selectedTab = tab
            let root = tab.paneRoot
            root.autoresizingMask = [.width, .height]
            // RESTORED-SPLIT COLLAPSE (founder's blank-pane-after-close class,
            // 2026-08-31/09-01): on the restore path attach()/select() run
            // BEFORE the window's first layout pass, so the auto-layouted
            // container still reports 0x0 here. Assigning that squeezed every
            // buildNode-built NSSplitView through zero size — the divider
            // position collapsed and the tree re-expanded with ALL width on
            // the first pane (restored 2-pane tabs presented 979/0 from
            // launch). Force the layout pass first so real bounds exist; if
            // the container STILL has no size, keep the tab's pre-attach
            // frame — TabContentContainerView.layout() adopts the real bounds
            // the moment they exist, and the tree never passes through zero.
            if contentContainer.bounds.width < 1 || contentContainer.bounds.height < 1 {
                window?.contentView?.layoutSubtreeIfNeeded()
            }
            if contentContainer.bounds.width >= 1, contentContainer.bounds.height >= 1 {
                root.frame = contentContainer.bounds
            }
            contentContainer.addSubview(root)
        }
        tab.noteSelected()
        refreshTitle()
        tabStrip.reload()
        if let pane = tab.currentPane() {
            window?.makeFirstResponder(pane)
        }
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// FR-59 swap primitive (custom-chrome stage 2): replaces this host's
    /// DISPLAYED tab set in place — same NSWindow, same frame, processes
    /// untouched. The outgoing tabs keep their views/panes/ptys; the caller
    /// re-homes them into another host (Workspaces.swapTabSets pairs a
    /// visible host with the incoming group's former hidden holder). A tab's
    /// pane root may currently be parented in ANOTHER host's container
    /// mid-swap, so detachment is guarded by superview identity.
    func setTabs(_ newTabs: [TerminalWindowController],
                 selecting: TerminalWindowController?) {
        if let sel = selectedTab, sel.paneRoot.superview === contentContainer {
            sel.paneRoot.removeFromSuperview()
        }
        selectedTab = nil
        for tab in tabs where tab.host === self { tab.host = nil }
        tabs = newTabs
        for tab in tabs { tab.host = self }
        updateChromeVisibility()
        tabStrip.reload()
        if let selecting, tabs.contains(where: { $0 === selecting }) {
            select(selecting)
        } else if let first = tabs.first {
            select(first)
        } else {
            refreshTitle()
        }
    }

    /// FR-59 crossfade, swap edition (founder: the hard cut read un-macOS):
    /// snapshot the window's current content, let the caller swap the tab set
    /// under it, and fade the snapshot out — an IN-WINDOW crossfade replacing
    /// the old window-alpha fade (the window itself no longer changes). Call
    /// BEFORE mutating the displayed tabs. Self-contained per host: a
    /// re-switch mid-fade just replaces the overlay, so there is no
    /// completion race with workspace state.
    func beginContentCrossfade() {
        guard let window, window.isVisible, let content = window.contentView,
              content.bounds.width > 0, content.bounds.height > 0 else { return }
        crossfadeOverlay?.removeFromSuperview()
        crossfadeOverlay = nil
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        let overlay = NSImageView(frame: content.bounds)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        crossfadeOverlay = overlay
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlay.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak overlay] in
            overlay?.removeFromSuperview()
            if let self, self.crossfadeOverlay === overlay { self.crossfadeOverlay = nil }
        })
    }

    func selectNextTab() { cycleTab(by: 1) }
    func selectPreviousTab() { cycleTab(by: -1) }

    private func cycleTab(by offset: Int) {
        guard tabs.count > 1,
              let current = tabs.firstIndex(where: { $0 === selectedTab }) else { return }
        select(tabs[(current + offset + tabs.count) % tabs.count])
    }

    /// In-strip drag reorder: order is first-class model state now — the
    /// journal's window rows record it via captureGroups (host.tabs order).
    func reorderTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to), from != to else { return }
        tabs = TabReorder.move(tabs, from: from, to: to)
        tabStrip.syncOrder()
    }

    func reorderCommitted() {
        app.memory?.scheduleTopologySave()
    }

    // MARK: - Chrome state

    /// The tab strip is ALWAYS visible under memterm's own chrome (stage 2:
    /// it is the window's titlebar surface — titles, rename, drag, activity
    /// all live there, so collapsing it would orphan them). The old
    /// `always_show_tab_bar` key is parsed as a documented no-op now. Only
    /// the workspace row remains toggleable (workspace_bar).
    func updateChromeVisibility() {
        let barVisible = app.config.workspaceBar
        barRow.isHidden = !barVisible
        tabStrip.isHidden = false
        // The TOP visible chrome row keeps its content clear of the traffic
        // lights; a strip below the workspace bar needs no extra inset.
        tabStrip.leadingInset = barVisible ? 8 : Self.trafficLightInset
        // The Settings gear was its own .right titlebar accessory before the
        // custom chrome — visible regardless of workspace_bar. With the bar
        // row (its current home) hidden, the strip shows its own gear so the
        // affordance never disappears.
        tabStrip.showsGear = !barVisible
    }

    /// Live config application (Settings changes): chrome rows + window-level
    /// theme (background / opacity / blur).
    func applyConfig(_ config: Config) {
        updateChromeVisibility()
        applyWindowChrome(config)
        // Appearance › Size scales the chrome rows too (ChromeMetrics): row
        // heights here, chip/pill fonts and decorations inside the views.
        let metrics = ChromeMetrics.derived(fromTerminalFontSize: config.fontSize)
        barRowHeight.constant = CGFloat(metrics.workspaceBarHeight)
        tabStripHeight.constant = CGFloat(metrics.tabStripHeight)
        workspaceBar?.applyMetrics(metrics)
        tabStrip.reload()
    }

    /// `window_opacity` / `window_blur`: window share of the theme (moved
    /// verbatim from the per-tab controller).
    func applyWindowChrome(_ config: Config) {
        guard let window else { return }
        let bg = config.themeBackgroundColor ?? .black
        let opaque = config.isWindowOpaque
        window.isOpaque = opaque
        window.backgroundColor = opaque
            ? bg : bg.withAlphaComponent(config.effectiveOpacity)
        // Council #2 ("two apps stacked"): the chrome derives its WORLD from
        // the theme ground, not from the system appearance — a light terminal
        // theme gets light chrome (dark labels, light materials) and vice
        // versa, keyed from the same ChromeContrast math the L2 seam pins
        // down. Every semantic color in the chips/tabs/gear resolves against
        // this window appearance, so both rows read as ONE app with the pane.
        let lightChrome = ChromeContrast.prefersLightChrome(
            themeBackground: config.themeBackground)
        window.appearance = NSAppearance(named: lightChrome ? .aqua : .darkAqua)
        blurView.isHidden = opaque || !config.windowBlur
        // The chrome rows never go translucent (founder bug 2026-09-01: at
        // window_opacity 0.37 the workspace chips washed out to invisible —
        // "we cannot see the workspaces"). Transparency is a terminal-content
        // effect; the strip/bar keep a solid ground like every browser's tab
        // bar over a translucent page.
        chromeStack.wantsLayer = true
        chromeStack.layer?.backgroundColor = bg.withAlphaComponent(1).cgColor
    }

    /// Called by tabs when their title, color, or activity mark changed.
    func tabChanged(_ tab: TerminalWindowController) {
        tabStrip.refreshItem(for: tab)
        if tab === selectedTab { refreshTitle() }
    }

    /// window.title tracks the selected tab (Mission Control / Window menu /
    /// accessibility) even though titleVisibility is .hidden.
    func refreshTitle() {
        window?.title = selectedTab?.displayTitle ?? "memterm"
    }

    func updateWorkspaceBar(workspaces: [WorkspaceRow], activeId: String,
                            activity: [String: TabActivityState] = [:]) {
        workspaceBar?.update(workspaces: workspaces, activeId: activeId, activity: activity)
        updateChromeVisibility()  // workspace_bar visibility follows config flips
    }

    /// Names the active workspace on the bar-row gear's tooltip. (When the
    /// workspace row is hidden, the strip's fallback gear keeps its generic
    /// tooltip — accepted divergence, tooltip-only.)
    func updateGearTooltip(workspaceName: String) {
        gearButton.toolTip = "Settings — workspace: \(workspaceName) (right-click to switch)"
    }

    func beginWorkspaceRename(_ workspaceId: String) {
        workspaceBar?.beginRename(workspaceId: workspaceId)
    }

    // MARK: - Probe support (MEMTERM_UI_PROBE)

    var isTabStripVisible: Bool { !tabStrip.isHidden }

    func workspaceBarFrameInWindow() -> NSRect? {
        guard let bar = workspaceBar, !barRow.isHidden, bar.window === window else { return nil }
        return bar.convert(bar.bounds, to: nil)
    }

    func tabStripFrameInWindow() -> NSRect? {
        guard !tabStrip.isHidden, tabStrip.window === window else { return nil }
        return tabStrip.convert(tabStrip.bounds, to: nil)
    }

    /// Council #10 alignment gate: the bar-row gear's frame in WINDOW
    /// coordinates (nil while the bar row is hidden — the strip shows its
    /// own gear then).
    func gearFrameInWindow() -> NSRect? {
        guard !barRow.isHidden, gearButton.window === window else { return nil }
        return gearButton.convert(gearButton.bounds, to: nil)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        app.noteHostFocused(self)
        // Everything on the selected tab is seen: its activity mark clears.
        selectedTab?.noteSelected()
    }

    func windowDidResignKey(_ notification: Notification) {
        if role == .dropdown { app.dropdown.panelResignedKey(self) }
    }

    func windowWillClose(_ notification: Notification) {
        firstResponderObservation = nil
        let remaining = tabs
        tabs = []
        selectedTab = nil
        // Traffic-light close = user close of ALL the host's tabs (Safari
        // convention). Quit / park / forget arrive here with isTerminating /
        // isSwitchingWorkspaces set, so the inference resolves to teardown —
        // the same discrimination the old per-tab windowWillClose applied.
        for tab in remaining {
            if tab.host === self { tab.host = nil }
            tab.teardown(userInitiated: tab.inferUserInitiatedClose())
        }
        app.hostClosed(self)
    }

    func windowDidResize(_ notification: Notification) {
        app.memory?.scheduleFrameSave()
    }

    func windowDidMove(_ notification: Notification) {
        app.memory?.scheduleFrameSave()
    }
}

/// The host's tab-content container. Its layout pass pins the hosted pane
/// root to its bounds whenever they are real — the structural guarantee that
/// a tree attached before the window's first layout (the restore path) adopts
/// the container's true size at the first opportunity instead of riding an
/// autoresize delta computed from a 0x0 parent (which mis-sizes splits and
/// was the restored-split zero-width collapse).
private final class TabContentContainerView: NSView {
    override func layout() {
        super.layout()
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        for sub in subviews where sub.frame != bounds {
            sub.frame = bounds
        }
    }
}

/// The drop-down panel's window: frames are never constrained to the screen
/// (it slides off its edge), and it can take keyboard focus without a
/// title bar's chrome.
final class DropdownWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
