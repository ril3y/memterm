import AppKit
import MemtermCore
import SwiftTerm

// One tab/window hosting a pane tree. Splits are plain nested NSSplitViews:
// splitting always wraps the target pane and the new pane in a fresh two-child
// split view, which gives arbitrary nesting with no separate tree model —
// the view hierarchy IS the tree (FR-3 groundwork).

enum FocusDirection {
    case left, right, up, down
}

final class TerminalWindowController: NSWindowController, NSWindowDelegate, LocalProcessTerminalViewDelegate {
    private unowned let app: MemtermAppDelegate
    /// Stable tab identity for the state store (one controller = one tab row).
    let tabId = UUID().uuidString
    /// FR-49: the workspace this tab belongs to (exactly one at a time;
    /// FR-58's "Move Tab to Workspace" / "New Workspace from Tab" reassign it
    /// through setWorkspace, never directly).
    private(set) var workspaceId: String

    /// FR-58: reassigns the tab to another workspace. Pure bookkeeping — the
    /// caller (MemtermAppDelegate.moveTab) handles tab-group membership and
    /// the topology save that rewrites both workspaces' rows.
    func setWorkspace(_ id: String) {
        workspaceId = id
    }
    /// User-chosen tab name (double-click the tab to set). While set, it
    /// pins the window/tab title — the automatic pane-title/cwd updates stop
    /// overwriting it. Persisted in the journal and restored (empty = auto).
    var customTitle: String? {
        didSet { refreshTitle() }
    }
    /// Founder 2026-08-31: per-tab color (hex), set via the tab's right-click
    /// menu, shown as a dot beside the activity indicator, journaled/restored.
    var tabColor: String? {
        didSet {
            updateTabColorDot()
            app.memory?.scheduleTopologySave()
        }
    }
    private let tabColorDot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    private weak var focusedPane: PaneView?
    // SwiftTerm's becomeFirstResponder is not open, so focus changes are
    // tracked by observing the window's firstResponder instead.
    private var firstResponderObservation: NSKeyValueObservation?
    /// Titlebar workspace chip (color dot + name; click = switcher menu).
    /// FR-58: right-click opens the same switcher menu as left-click.
    private let workspaceChipButton = ChipButton()
    /// The workspace bar (WorkspaceBar.swift), hosted in a .top titlebar
    /// accessory ABOVE the native tab strip (founder: "workspaces should be
    /// on top then tabs below it"); the pane tree fills the full content
    /// layout area beneath the chrome.
    private(set) var workspaceBar: WorkspaceBarView?
    /// The .top accessory hosting `workspaceBar`; nil while workspace_bar=false
    /// (removing it also restores the titlebar's window title).
    private var workspaceBarAccessory: NSTitlebarAccessoryViewController?
    private let terminalContainer = NSView()
    /// `window_blur`: behind-window blur, shown only while the window is
    /// translucent (Settings 2.0). Public NSVisualEffectView — no private
    /// CGS blur API.
    private let blurView = NSVisualEffectView()
    /// Per-tab activity indicator (spinner while output flows on a
    /// non-selected tab, decaying to an unseen-output dot; TabActivity.swift).
    private let activityIndicator = TabActivityIndicatorView()
    private var activity = TabActivityTracker()
    private var activityRefreshWork: DispatchWorkItem?

    /// `initialCwd`: where the first pane's shell starts (nil = home). ⌘T/⌘N
    /// pass the key pane's kernel-truth cwd here when `new_tab_same_cwd` is on
    /// (iTerm2's "reuse previous session's directory"); restore paths ignore
    /// it (each restored pane carries its own journaled cwd).
    init(app: MemtermAppDelegate, workspaceId: String = StateStore.defaultWorkspaceId,
         restoredTab: TabRestore? = nil, restoredFrame: NSRect? = nil,
         initialCwd: String? = nil) {
        self.app = app
        self.workspaceId = workspaceId
        let rect = NSRect(x: 0, y: 0, width: 980, height: 640)
        // .fullSizeContentView is required for the workspace bar's .top
        // titlebar accessory (feasibility study, macOS 26.2); the terminal
        // never draws under the chrome because terminalContainer is pinned to
        // contentLayoutGuide, which excludes titlebar + accessory + tab strip.
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "memterm"
        window.tabbingIdentifier = "memterm-terminal"
        if let restoredFrame {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.center()
        }
        if let bg = app.config.themeBackgroundColor { window.backgroundColor = bg }
        super.init(window: window)
        window.delegate = self
        installWorkspaceChip(on: window)
        do {
            tabColorDot.wantsLayer = true
            tabColorDot.layer?.cornerRadius = 4
            tabColorDot.isHidden = true
            tabColorDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            tabColorDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            let accessory = NSStackView(views: [tabColorDot, activityIndicator])
            accessory.orientation = .horizontal
            accessory.spacing = 3
            window.tab.accessoryView = accessory
        }
        // PINNED DEPENDENCY: NSWindow.firstResponder is not documented as
        // KVO-compliant (it works on every macOS to date). If a macOS update
        // stops emitting changes here, focusedPane stops updating and
        // currentPane() silently degrades to its firstResponder-cast /
        // allPanes().first fallback — check here first if multi-pane focus
        // targeting (⌘R/⌘F/splits) regresses after an OS update.
        firstResponderObservation = window.observe(\.firstResponder) { [weak self] window, _ in
            if let pane = window.firstResponder as? PaneView {
                self?.paneFocused(pane)
            }
        }

        let content = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        window.contentView = content
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.isHidden = true
        content.addSubview(blurView)
        content.addSubview(terminalContainer)
        applyWindowChrome(app.config)
        let bar = WorkspaceBarView(app: app)
        workspaceBar = bar
        setWorkspaceBarVisible(app.config.workspaceBar)
        // With .fullSizeContentView the content view spans the whole window;
        // contentLayoutGuide tracks the region below titlebar + top accessory
        // + tab strip, through tab-bar show/hide and fullscreen transitions.
        if let guide = window.contentLayoutGuide as? NSLayoutGuide {
            for view in [blurView, terminalContainer] {
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                    view.topAnchor.constraint(equalTo: guide.topAnchor),
                    view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                ])
            }
        }
        // Pre-layout bounds so the initial pane/split tree is built against a
        // realistic size (Auto Layout replaces this on the first pass).
        terminalContainer.frame = window.contentLayoutRect
        let root: NSView
        if let restoredTab {
            root = buildNode(restoredTab.tree, frame: terminalContainer.bounds,
                             panes: restoredTab.panes)
        } else {
            // A vanished inherited cwd falls back like a restore would —
            // never a broken pane (FR-25 spirit).
            let cwd = initialCwd.map { CwdFallback.resolve($0).path }
            root = makePane(frame: terminalContainer.bounds, cwd: cwd)
        }
        terminalContainer.addSubview(root)
        if let restoredTab, !restoredTab.title.isEmpty {
            // Only custom names are journaled (auto titles regenerate live).
            customTitle = restoredTab.title
        }
        if let restoredTab, let color = restoredTab.color, !color.isEmpty {
            tabColor = color
        }
        if let first = allPanes().first {
            window.makeFirstResponder(first)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Tab bar policy (founder: single-tab windows must show their tab)

    /// `always_show_tab_bar`: with one tab, macOS hides the tab bar, making
    /// double-click rename unreachable — toggle it visible. The check makes
    /// this idempotent (toggleTabBar is a flip, never call it blind), which
    /// also means calling it for several controllers of one tab group is safe:
    /// the first call flips, the rest see the bar already visible and no-op.
    func applyTabBarPolicy(alwaysShow: Bool) {
        guard let window, let group = window.tabGroup else { return }
        if alwaysShow, !group.isTabBarVisible {
            window.toggleTabBar(nil)
        } else if !alwaysShow, group.isTabBarVisible, group.windows.count <= 1 {
            window.toggleTabBar(nil)
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if app.config.alwaysShowTabBar { applyTabBarPolicy(alwaysShow: true) }
    }

    // MARK: - Titlebar gear (founder 2026-08-31: the workspace chip duplicated
    // the workspace bar — replaced by a gear: click opens Settings, right-click
    // still pops the workspace switcher)

    private func installWorkspaceChip(on window: NSWindow) {
        workspaceChipButton.menuProvider = { [weak self] in
            self.map { $0.app.makeWorkspacePopUpMenu() }
        }
        workspaceChipButton.isBordered = false
        workspaceChipButton.setButtonType(.momentaryChange)
        workspaceChipButton.image = NSImage(systemSymbolName: "gearshape",
                                            accessibilityDescription: "Settings")
        workspaceChipButton.contentTintColor = .secondaryLabelColor
        workspaceChipButton.toolTip = "Settings (right-click: workspaces)"
        workspaceChipButton.target = app
        workspaceChipButton.action = #selector(MemtermAppDelegate.openPreferences(_:))
        workspaceChipButton.frame = NSRect(x: 0, y: 0, width: 24, height: 20)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 22))
        workspaceChipButton.setFrameOrigin(NSPoint(x: 4, y: 1))
        container.addSubview(workspaceChipButton)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    // MARK: - Workspace bar (founder UX: visible workspaces ABOVE the tabs)

    /// Installs/removes the bar's .top titlebar accessory (one per window,
    /// like the .right gear). Verified on macOS 26.2: with .fullSizeContentView
    /// a .top accessory renders ABOVE the native tab strip, per-window, without
    /// the .bottom stacking bug (see the WorkspaceBar.swift header). Known
    /// trade-off: while a .top accessory is present AppKit auto-hides the
    /// titlebar's window-title text — acceptable because memterm shows the tab
    /// bar by default (tab titles carry the info); with always_show_tab_bar =
    /// false AND workspace_bar = true the title is not visible on a single-tab
    /// window. Removing the accessory (workspace_bar = false) restores the
    /// native title automatically.
    private func setWorkspaceBarVisible(_ visible: Bool) {
        guard let window, let bar = workspaceBar else { return }
        if visible {
            guard workspaceBarAccessory == nil else { return }
            bar.frame = NSRect(x: 0, y: 0, width: window.frame.width,
                               height: WorkspaceBarView.height)
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = bar
            accessory.layoutAttribute = .top
            window.addTitlebarAccessoryViewController(accessory)
            workspaceBarAccessory = accessory
        } else if let accessory = workspaceBarAccessory {
            accessory.removeFromParent()
            workspaceBarAccessory = nil
        }
    }

    func updateWorkspaceBar(workspaces: [WorkspaceRow], activeId: String,
                            activity: [String: TabActivityState] = [:]) {
        workspaceBar?.update(workspaces: workspaces, activeId: activeId, activity: activity)
        setWorkspaceBarVisible(app.config.workspaceBar)  // follows config flips
    }

    func beginWorkspaceRename(_ workspaceId: String) {
        workspaceBar?.beginRename(workspaceId: workspaceId)
    }

    /// Bottom edge (window coords) of the native tab strip: the top of the
    /// content layout area — with .fullSizeContentView, contentLayoutRect
    /// excludes ALL titlebar chrome (titlebar row, .top workspace-bar
    /// accessory, tab strip), so its maxY is the strip's bottom edge. Shared
    /// by the double-click-rename and right-click-menu monitors (which also
    /// exclude the workspace bar's own frame — see tabStripController).
    func tabStripBottomY() -> CGFloat {
        window?.contentLayoutRect.maxY ?? 0
    }

    /// The workspace bar's frame in window coords, when it is installed in
    /// this window's titlebar (nil while workspace_bar=false). Used by the
    /// tab-strip gesture monitors and the UI probe.
    func workspaceBarFrameInWindow() -> NSRect? {
        guard let bar = workspaceBar, workspaceBarAccessory != nil,
              bar.window === window else { return nil }
        return bar.convert(bar.bounds, to: nil)
    }

    /// The gear replaced the name/color chip; the workspace identity lives in
    /// the workspace bar now, so this only keeps the tooltip current.
    func updateWorkspaceChip(name: String, color: NSColor) {
        workspaceChipButton.toolTip = "Settings — workspace: \(name) (right-click to switch)"
    }

    // MARK: - Pane context menu (FR-58: right-click is a first-class affordance)

    /// Built fresh per right-click (workspace list changes). The pane is made
    /// first responder first, so responder-chain items (copy:/paste:) and
    /// currentPane()-based actions all target the clicked pane.
    ///
    /// FACT (recorded at the FR-58 investigation): SwiftTerm's MacTerminalView
    /// overrides neither rightMouseDown nor menu(for:) — right-clicks are not
    /// forwarded to the pty even under mouse reporting (only encodeMouseEvent
    /// can encode .rightMouseUp, and nothing routes right-button events into
    /// it). There is no existing right-click behavior to preserve.
    func contextMenu(for pane: PaneView) -> NSMenu {
        window?.makeFirstResponder(pane)
        let menu = NSMenu(title: "Pane")

        func add(_ title: String, _ action: Selector, target: AnyObject?,
                 represented: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = represented
            menu.addItem(item)
        }
        // nil target: copy:/paste: resolve through the responder chain to the
        // (now focused) terminal view.
        add("Copy", #selector(NSText.copy(_:)), target: nil)
        add("Paste", #selector(NSText.paste(_:)), target: nil)
        menu.addItem(.separator())
        add("Split Right", #selector(ctxSplitRight(_:)), target: self)
        add("Split Down", #selector(ctxSplitDown(_:)), target: self)
        menu.addItem(.separator())
        add("Clear", #selector(ctxClear(_:)), target: self, represented: pane)
        add("Forget Pane Memory", #selector(ctxForgetPaneMemory(_:)), target: self,
            represented: pane)
        menu.addItem(.separator())

        // FR-58: creating a workspace must be reachable by right-click alone.
        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        workspaceItem.submenu = app.makeWorkspaceContextMenu(for: self)
        menu.addItem(workspaceItem)
        menu.addItem(.separator())
        add("Close Pane", #selector(ctxClosePane(_:)), target: self, represented: pane)
        return menu
    }

    @objc private func ctxSplitRight(_ sender: Any?) { splitCurrentPane(vertical: true) }
    @objc private func ctxSplitDown(_ sender: Any?) { splitCurrentPane(vertical: false) }

    @objc private func ctxClear(_ sender: NSMenuItem) {
        (sender.representedObject as? PaneView)?.clearScrollback()
    }

    /// FR-57: rows + scrollback file for this pane; the pane stays open and
    /// the next capture tick starts a fresh journal trail.
    @objc private func ctxForgetPaneMemory(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? PaneView else { return }
        app.memory?.forgetPane(pane.paneId)
    }

    @objc private func ctxClosePane(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? PaneView else { return }
        close(pane: pane)
    }

    // MARK: - Panes

    private func makePane(frame: NSRect, cwd: String?) -> PaneView {
        let pane = constructPane(frame: frame)
        pane.lastKnownCwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        startShell(in: pane, cwd: cwd)
        return pane
    }

    private func constructPane(frame: NSRect) -> PaneView {
        let config = app.config
        let options = TerminalOptions(cursorStyle: config.terminalCursorStyle,
                                      scrollback: config.scrollbackLines)
        let pane = PaneView(frame: frame, font: app.currentFont(), options: options)
        pane.autoresizingMask = [.width, .height]
        pane.copyOnSelect = config.copyOnSelect
        pane.optionAsMetaKey = config.optionAsMeta
        pane.bellStyle = config.terminalBellStyle
        pane.bellSoundName = config.bellSound
        pane.allowMouseReporting = config.allowMouseReporting
        if config.lineSpacing != 1.0 { pane.lineSpacing = CGFloat(config.lineSpacing) }
        pane.processDelegate = self
        // Transparency is background-color ALPHA (SwiftTerm's CoreText path
        // deliberately preserves a translucent background), never window
        // alpha — text stays fully opaque.
        let opacity = config.effectiveOpacity
        if let bg = config.themeBackgroundColor {
            pane.nativeBackgroundColor = config.isWindowOpaque
                ? bg : bg.withAlphaComponent(opacity)
        } else if !config.isWindowOpaque {
            pane.nativeBackgroundColor = NSColor.black.withAlphaComponent(opacity)
        }
        if let fg = config.themeForegroundColor { pane.nativeForegroundColor = fg }
        if let cursor = config.themeCursorColor { pane.caretColor = cursor }
        if let selection = config.themeSelectionColor {
            pane.selectedTextBackgroundColor = selection
        }
        if let ansi = config.terminalAnsiColors { pane.installColors(ansi) }
        pane.onOutputActivity = { [weak self] in self?.paneProducedOutput() }
        pane.onBell = { [weak self] in self?.paneRangBell() }
        return pane
    }

    /// BEL beyond the in-view sound/flash (SwiftTerm's bellStyle handled
    /// those in the pane): a bell on a non-selected tab marks its activity
    /// indicator, and a bell while memterm is in the background bounces the
    /// dock once — the classic "long build finished" signal.
    private func paneRangBell() {
        paneProducedOutput()
        if !NSApp.isActive {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    // MARK: - Tab activity (founder UX: spinner / unseen dot on the tab)

    /// "Selected" for activity purposes: the tab the user is looking at in its
    /// window. A window not in a multi-tab group is its own selected tab.
    private var isSelectedTab: Bool {
        guard let window else { return true }
        if let group = window.tabGroup, group.windows.count > 1 {
            return group.selectedWindow === window
        }
        return true
    }

    /// Called from PaneView.dataReceived (main thread — LocalProcess delivers
    /// on DispatchQueue.main). Coalesced by the tracker to ≤1 UI update per
    /// 250 ms per tab, so flood output never churns the tab bar.
    func paneProducedOutput() {
        let now = ProcessInfo.processInfo.systemUptime
        if activity.recordOutput(at: now, isSelected: isSelectedTab) {
            refreshActivityIndicator()
        } else {
            scheduleActivityRefresh(after: activity.coalesceInterval)
        }
        // Founder UX: output in a HIDDEN workspace marks its chip in the
        // workspace bar (pulse → unseen ring). The app-level center owns the
        // per-workspace state; it ignores the active workspace.
        app.workspaceProducedOutput(workspaceId)
    }

    private func refreshActivityIndicator() {
        activityRefreshWork?.cancel()
        activityRefreshWork = nil
        let now = ProcessInfo.processInfo.systemUptime
        activityIndicator.apply(state: activity.state(at: now))
        // While active, one more repaint just past the decay boundary flips
        // the spinner to the solid unseen-output dot.
        if let decayAt = activity.nextDecay(after: now) {
            scheduleActivityRefresh(after: decayAt - now + 0.05)
        }
    }

    /// MEMTERM_UI_PROBE support: the tracker's current state.
    func activityStateForProbe() -> TabActivityState {
        activity.state(at: ProcessInfo.processInfo.systemUptime)
    }

    private func scheduleActivityRefresh(after delay: TimeInterval) {
        guard activityRefreshWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.activityRefreshWork = nil
            self?.refreshActivityIndicator()
        }
        activityRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.05), execute: work)
    }

    private func startShell(in pane: PaneView, cwd: String?, shellOverride: String? = nil) {
        var shell = shellOverride ?? app.config.shell
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if !FileManager.default.isExecutableFile(atPath: shell) { shell = "/bin/zsh" }
        pane.shellPath = shell
        let shellName = (shell as NSString).lastPathComponent
        // Shell integration (FR-5 / per-tab ↑ history): zsh panes spawn with
        // the ZDOTDIR wrapper env. The base is EXACTLY what SwiftTerm uses
        // for a nil environment (verified in LocalProcess.startProcess), so
        // integration only ADDS variables; any other shell — or the config
        // key off, or a failed wrapper install — passes nil and spawns
        // exactly as before. Restored panes have their journaled paneId set
        // before this runs, so the seeded .hist is the same tab's.
        var environment: [String]?
        if app.config.shellIntegration, ShellIntegration.isZsh(shellPath: shell),
           let integrationDir = app.memory?.shellIntegrationDir,
           let historyDir = app.memory?.historyDir {
            let processEnv = ProcessInfo.processInfo.environment
            let userZdotdir = processEnv["ZDOTDIR"]
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            environment = ShellIntegration.environment(
                base: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                paneId: pane.paneId,
                histDir: historyDir.path,
                userZdotdir: userZdotdir,
                integrationDir: integrationDir.path)
        }
        pane.startProcess(executable: shell, environment: environment,
                          execName: "-\(shellName)", currentDirectory: cwd)
    }

    // MARK: - Restore (FR-24/25, v0 chips as feed()'d offer lines)

    private func buildNode(_ node: SplitNode, frame: NSRect, panes: [String: PaneRestore]) -> NSView {
        switch node {
        case .pane(let id):
            return makeRestoredPane(frame: frame, id: id, restore: panes[id])
        case .split(let vertical, let ratio, let first, let second):
            let split = NSSplitView(frame: frame)
            split.isVertical = vertical
            split.dividerStyle = .thin
            split.autoresizingMask = [.width, .height]
            var fa = frame, fb = frame
            if vertical {
                fa.size.width = frame.width * ratio
                fb.size.width = frame.width - fa.width
            } else {
                fa.size.height = frame.height * ratio
                fb.size.height = frame.height - fa.height
            }
            split.addArrangedSubview(buildNode(first, frame: fa, panes: panes))
            split.addArrangedSubview(buildNode(second, frame: fb, panes: panes))
            split.adjustSubviews()
            split.setPosition((vertical ? frame.width : frame.height) * ratio, ofDividerAt: 0)
            return split
        }
    }

    private static let restoreDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d h:mm a"
        return f
    }()

    private func makeRestoredPane(frame: NSRect, id: String, restore: PaneRestore?) -> PaneView {
        let (cwd, fellBack) = CwdFallback.resolve(restore?.cwd)
        let pane = constructPane(frame: frame)
        pane.paneId = id
        pane.lastKnownCwd = cwd
        pane.cwdSource = "restore"

        // Ghost scrollback: history the user can scroll/search. feed() only —
        // nothing here ever reaches the pty.
        if let ghost = app.memory?.loadScrollback(for: id), !ghost.isEmpty {
            let crlf = ScrollbackText.ghostFeedText(ghost)
            pane.feed(text: "\u{1b}[2m" + crlf + "\u{1b}[0m\r\n")
        }
        let stamp = Self.restoreDateFormatter.string(from: Date())
        pane.feed(text: "\u{1b}[36m── restored — \(stamp) ──\u{1b}[0m\r\n")
        pane.restoredDividerCount += 1
        if fellBack, let saved = restore?.cwd {
            pane.feed(text: "\u{1b}[2mmemterm: directory not available: \(saved)\u{1b}[0m\r\n")
        }
        if var snap = restore?.snapshot, !snap.adapter.isEmpty {
            // FR-36/§9: the same Claude session UUID is never offered on two
            // panes. First pane claims it; later panes with the same UUID
            // (same-cwd fallback ambiguity) downgrade to `claude --continue`,
            // honestly labeled by resumeOffer.
            if snap.adapter == "claude",
               let sessionId = snap.adapterState["sessionId"], !sessionId.isEmpty,
               !app.claudeClaims.claim(sessionId: sessionId, paneId: id) {
                snap.adapterState["sessionId"] = nil
            }
            // FR-25 second half: a fallback cwd disables cwd-dependent offers
            // (watchers, `claude --continue`); `claude --resume <uuid>` stays
            // with a "project directory unavailable" caveat in its label.
            if let offer = Adapters.resumeOffer(for: snap, cwdUnavailable: fellBack) {
                pane.pendingResumeCommand = offer.command
                pane.feed(text: "\u{1b}[36mmemterm: was running \(offer.label) — press ⌘R to type: \(offer.command)\u{1b}[0m\r\n")
            }
        }
        startShell(in: pane, cwd: cwd, shellOverride: restore?.shell)
        return pane
    }

    // MARK: - Capture (split tree snapshot for the state store)

    func snapshotTab() -> TabSnap? {
        guard let root = terminalContainer.subviews.first,
              let tree = snapshotNode(root) else { return nil }
        let panes = allPanes().map {
            PaneSnap(id: $0.paneId, shell: $0.shellPath, cwd: $0.lastKnownCwd,
                     cwdSource: $0.cwdSource)
        }
        // Custom names only: a stored auto title would freeze as custom on
        // restore. Auto titles regenerate from pane title/cwd anyway.
        return TabSnap(id: tabId, title: customTitle ?? "", tree: tree, panes: panes,
                       color: tabColor)
    }

    private func snapshotNode(_ view: NSView) -> SplitNode? {
        if let pane = view as? PaneView { return .pane(pane.paneId) }
        guard let split = view as? NSSplitView else { return nil }
        let subs = split.arrangedSubviews
        if subs.count == 2, let a = snapshotNode(subs[0]), let b = snapshotNode(subs[1]) {
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            let first = split.isVertical ? subs[0].frame.width : subs[0].frame.height
            let ratio = total > 0 ? Double(first / total) : 0.5
            return .split(vertical: split.isVertical, ratio: min(max(ratio, 0.05), 0.95),
                          first: a, second: b)
        }
        return subs.count == 1 ? snapshotNode(subs[0]) : nil
    }

    func allPanes() -> [PaneView] {
        guard let content = window?.contentView else { return [] }
        var result: [PaneView] = []
        func walk(_ view: NSView) {
            if let pane = view as? PaneView { result.append(pane); return }
            view.subviews.forEach(walk)
        }
        walk(content)
        return result
    }

    func currentPane() -> PaneView? {
        if let pane = window?.firstResponder as? PaneView { return pane }
        if let pane = focusedPane { return pane }
        return allPanes().first
    }

    private func paneFocused(_ pane: PaneView) {
        focusedPane = pane
        let panes = allPanes()
        // Slight dimming makes the focused pane identifiable with several up.
        for p in panes {
            p.alphaValue = (panes.count > 1 && p !== pane) ? 0.72 : 1.0
        }
        refreshTitle(for: pane)
    }

    // MARK: - Splits

    func splitCurrentPane(vertical: Bool) {
        guard let pane = currentPane() else { return }
        let oldFrame = pane.frame
        // Kernel-truth cwd first (works without shell integration), OSC 7 as
        // the fallback for a pane the 2 s poll hasn't visited yet.
        let inherited = pane.lastKnownCwd ?? pane.currentLocalDirectory
        let newPane = makePane(frame: oldFrame,
                               cwd: inherited.map { CwdFallback.resolve($0).path })
        let split = NSSplitView(frame: oldFrame)
        split.isVertical = vertical  // vertical divider = panes side by side
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        replace(pane, with: split)
        split.addArrangedSubview(pane)
        split.addArrangedSubview(newPane)
        split.adjustSubviews()
        split.setPosition((vertical ? oldFrame.width : oldFrame.height) / 2, ofDividerAt: 0)
        window?.makeFirstResponder(newPane)
        app.memory?.scheduleTopologySave()
    }

    func closeCurrentPane() {
        guard let pane = currentPane() else { return }
        close(pane: pane)
    }

    func close(pane: PaneView) {
        pane.processDelegate = nil
        app.claudeClaims.release(paneId: pane.paneId)
        if pane.process.running { pane.terminate() }

        guard let split = pane.superview as? NSSplitView else {
            // Root (only) pane: close the tab/window (FR-56 forget happens in
            // windowWillClose, which discriminates user close from teardown).
            window?.close()
            return
        }
        // FR-56: a user-initiated pane close forgets that pane NOW — journal
        // rows and scrollback bytes. Quit/park teardown never reaches here
        // (windowWillClose detaches processDelegate before terminating), but
        // the flags guard it anyway. FR-59: a pane in a HIDDEN workspace can
        // only get here via processTerminated (its shell died on its own) —
        // no user gesture is possible there, so it never forgets.
        if !app.isTerminating && !app.isSwitchingWorkspaces
            && workspaceId == app.activeWorkspaceId {
            app.memory?.forgetPane(pane.paneId)
        }
        split.removeArrangedSubview(pane)
        pane.removeFromSuperview()
        if split.arrangedSubviews.count == 1 {
            // Unwrap the now-single-child split so nesting depth matches reality.
            let remaining = split.arrangedSubviews[0]
            split.removeArrangedSubview(remaining)
            remaining.removeFromSuperview()
            remaining.frame = split.frame
            replace(split, with: remaining)
            // Founder bug 2026-08-31 ("closed both", tab looked blank): after
            // the view swap, force layout + repaint of the survivor — a
            // structurally-correct pane that never redraws looks exactly like
            // a closed one.
            remaining.needsLayout = true
            remaining.needsDisplay = true
        }
        window?.contentView?.needsLayout = true
        if let next = allPanes().first {
            window?.makeFirstResponder(next)
            next.needsDisplay = true
        }
        app.memory?.scheduleTopologySave()
    }

    private func replace(_ old: NSView, with new: NSView) {
        guard let parent = old.superview else { return }
        new.frame = old.frame
        if let parentSplit = parent as? NSSplitView,
           let idx = parentSplit.arrangedSubviews.firstIndex(of: old) {
            parentSplit.removeArrangedSubview(old)
            old.removeFromSuperview()
            parentSplit.insertArrangedSubview(new, at: idx)
        } else {
            parent.replaceSubview(old, with: new)
        }
    }

    // MARK: - Focus movement (⌘⌥ arrows): nearest pane center in the direction.

    func moveFocus(_ direction: FocusDirection) {
        guard let current = currentPane(), let window else { return }
        let panes = allPanes().filter { $0 !== current }
        guard !panes.isEmpty else { return }

        func center(_ v: NSView) -> NSPoint {
            let r = v.convert(v.bounds, to: window.contentView)
            return NSPoint(x: r.midX, y: r.midY)
        }
        let from = center(current)
        var best: (pane: PaneView, distance: CGFloat)?
        for pane in panes {
            let to = center(pane)
            let dx = to.x - from.x, dy = to.y - from.y
            let matches: Bool
            switch direction {
            case .left:  matches = dx < 0 && abs(dx) >= abs(dy)
            case .right: matches = dx > 0 && abs(dx) >= abs(dy)
            case .up:    matches = dy > 0 && abs(dy) >= abs(dx)  // AppKit y grows upward
            case .down:  matches = dy < 0 && abs(dy) >= abs(dx)
            }
            guard matches else { continue }
            let dist = dx * dx + dy * dy
            if best == nil || dist < best!.distance { best = (pane, dist) }
        }
        if let best { window.makeFirstResponder(best.pane) }
    }

    // MARK: - Appearance

    func applyFont(_ font: NSFont) {
        for pane in allPanes() { pane.font = font }
    }

    /// `window_opacity` / `window_blur`: the window's share of the theme.
    /// Opacity is background-color alpha with isOpaque=false (never window
    /// alphaValue — glyphs stay crisp); the blur is our NSVisualEffectView
    /// behind the terminal, only while translucent.
    private func applyWindowChrome(_ config: Config) {
        guard let window else { return }
        let bg = config.themeBackgroundColor ?? .black
        let opaque = config.isWindowOpaque
        window.isOpaque = opaque
        window.backgroundColor = opaque
            ? bg : bg.withAlphaComponent(config.effectiveOpacity)
        blurView.isHidden = opaque || !config.windowBlur
    }

    /// Live theme application from the Settings window. Explicit defaults are
    /// pushed when the theme is cleared so panes don't keep stale colors.
    func applyTheme(_ config: Config) {
        let opaque = config.isWindowOpaque
        let opacity = config.effectiveOpacity
        let bg = config.themeBackgroundColor ?? .black
        let fg = config.themeForegroundColor
            ?? NSColor(srgbRed: 0.77, green: 0.78, blue: 0.78, alpha: 1)
        applyWindowChrome(config)
        for pane in allPanes() {
            pane.copyOnSelect = config.copyOnSelect
            pane.optionAsMetaKey = config.optionAsMeta
            pane.bellStyle = config.terminalBellStyle
            pane.bellSoundName = config.bellSound
            pane.allowMouseReporting = config.allowMouseReporting
            // Live cursor restyle (Terminal.setCursorStyle is public —
            // verified in SwiftTerm's Terminal.swift:4123).
            pane.getTerminal().setCursorStyle(config.terminalCursorStyle)
            pane.nativeBackgroundColor = opaque ? bg : bg.withAlphaComponent(opacity)
            pane.nativeForegroundColor = fg
            pane.caretColor = config.themeCursorColor ?? fg
            pane.selectedTextBackgroundColor = config.themeSelectionColor
                ?? Config.defaultSelectionColor
            // lineSpacing's setter does a full font reset — only touch it on
            // an actual change (applyTheme runs on every Settings tweak).
            let spacing = CGFloat(config.lineSpacing)
            if pane.lineSpacing != spacing { pane.lineSpacing = spacing }
            // A cleared palette (Use Default Colors) must push SwiftTerm's
            // defaults back, or panes keep the previous preset's 16 ANSI
            // colors until relaunch — the exact stale-color half-apply the
            // "explicit defaults" contract above forbids.
            pane.installColors(config.terminalAnsiColors ?? SwiftTerm.Color.defaultInstalledColors)
            pane.needsDisplay = true
        }
    }

    private func refreshTitle(for pane: PaneView) {
        guard pane === currentPane() else { return }
        refreshTitle()
    }

    private func refreshTitle() {
        defer { updateTabColorDot() }  // the color pill wraps the live title
        if let customTitle {
            window?.title = customTitle
            return
        }
        guard let pane = currentPane() else {
            window?.title = "memterm"
            return
        }
        if !pane.paneTitle.isEmpty {
            window?.title = pane.paneTitle
        } else if let dir = pane.currentLocalDirectory {
            window?.title = (dir as NSString).abbreviatingWithTildeInPath
        } else {
            window?.title = "memterm"
        }
    }

    /// Double-click on the tab (FR: founder request 2026-08-31). Empty input
    /// clears the custom name and automatic titles resume.
    /// Founder (screenshot, 2026-08-31): the tab color reads as a PILL behind
    /// the tab's title, not a dot. The native tab bar is private AppKit, so
    /// the whole-tab tint iTerm2 draws (custom chrome) isn't reachable; the
    /// public-API equivalent is NSWindowTab.attributedTitle with a colored
    /// background behind padded title text — visually the pill in the
    /// founder's screenshot. Text flips black/white by luminance.
    private func updateTabColorDot() {
        tabColorDot.isHidden = true  // superseded by the pill
        guard let window else { return }
        guard let tabColor else {
            window.tab.attributedTitle = nil
            return
        }
        let color = MemtermAppDelegate.nsColor(hex: tabColor)
        let srgb = color.usingColorSpace(.sRGB) ?? color
        let luminance = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent
            + 0.114 * srgb.blueComponent
        window.tab.attributedTitle = NSAttributedString(
            string: "  \(window.title)  ",
            attributes: [
                .backgroundColor: color,
                .foregroundColor: luminance > 0.55 ? NSColor.black : NSColor.white,
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            ])
    }

    @objc func ctxSetTabColor(_ sender: NSMenuItem) {
        let hex = sender.representedObject as? String
        tabColor = (hex?.isEmpty ?? true) ? nil : hex
    }

    func promptRenameTab() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to go back to automatic titles."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = customTitle ?? ""
        field.placeholderString = window.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        // A sheet (not runModal): native look, and — unlike runModal, which
        // ignores initialFirstResponder for accessory views — focus + select-
        // all actually land, so typing immediately replaces the old name.
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            self.customTitle = name.isEmpty ? nil : name
            self.app.memory?.scheduleTopologySave()
        }
        alert.window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    // MARK: - NSWindowDelegate

    /// Selecting a tab makes its window key: everything is seen, the
    /// indicator clears.
    func windowDidBecomeKey(_ notification: Notification) {
        activity.recordSelected()
        refreshActivityIndicator()
        // Re-assert only the "show" half of the policy here: closing the
        // second-to-last tab makes AppKit hide the bar again, and the surviving
        // tab becomes key right after. (The "hide" half runs only on an
        // explicit settings change — never fight a user who showed it by hand.)
        if app.config.alwaysShowTabBar { applyTabBarPolicy(alwaysShow: true) }
    }

    func windowWillClose(_ notification: Notification) {
        activityRefreshWork?.cancel()
        activityRefreshWork = nil
        // FR-56 discrimination: this fires for user closes (⌘W, close button,
        // native tab close) AND for teardown closes (⌘Q quit, workspace
        // park/forget). Only the user gesture forgets — quit is "put it
        // down", close is "throw it away", crash runs nothing at all.
        // FR-59: a hidden workspace's window has no on-screen UI, so no user
        // gesture can close it — if macOS ever closes one behind our back,
        // that is teardown, never a forget.
        let userInitiated = !app.isTerminating && !app.isSwitchingWorkspaces
            && workspaceId == app.activeWorkspaceId
        let paneIds = allPanes().map { $0.paneId }
        for pane in allPanes() {
            pane.processDelegate = nil
            app.claudeClaims.release(paneId: pane.paneId)
            if pane.process.running { pane.terminate() }
        }
        app.controllerClosed(self)
        if userInitiated {
            // Immediate row purge + scrollback file delete: the closed tab
            // must never restore, even if the app dies before the next
            // debounced topology save runs.
            app.memory?.forgetTab(tabId: tabId, paneIds: paneIds)
        }
        app.memory?.scheduleTopologySave()
        // FR-59 corollary: never leave the app windowless while other
        // workspaces hold hidden live windows — surface the MRU one.
        app.activeWorkspaceWindowClosed(workspaceId, userInitiated: userInitiated)
    }

    func windowDidResize(_ notification: Notification) {
        app.memory?.scheduleFrameSave()
    }

    func windowDidMove(_ notification: Notification) {
        app.memory?.scheduleFrameSave()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard let pane = source as? PaneView else { return }
        pane.paneTitle = title
        refreshTitle(for: pane)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let pane = source as? PaneView else { return }
        pane.updateLocalDirectory(fromOSC7: directory)
        refreshTitle(for: pane)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let pane = source as? PaneView else { return }
        close(pane: pane)
    }
}

/// Titlebar chip button whose right-click shows the same menu the left-click
/// action pops up (FR-58). NSView's default rightMouseDown displays whatever
/// menu(for:) returns.
final class ChipButton: NSButton {
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }
}
