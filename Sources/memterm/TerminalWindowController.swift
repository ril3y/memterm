import AppKit
import MemtermCore
import MemtermExtensionKit
import SwiftTerm

// One TAB hosting a pane tree (custom-tab-chrome stage: this class is the
// TabModel — it no longer owns an NSWindow; a WindowHostController displays
// one tab at a time and owns the window, chrome, and window-delegate duties).
// The name is kept from the native-tab era to minimize churn; the journal's
// identifiers (tabId, panes) are unchanged, so state.db needs no migration.
//
// Splits are plain nested NSSplitViews inside `paneRoot`: splitting always
// wraps the target pane and the new pane in a fresh two-child split view,
// which gives arbitrary nesting with no separate tree model — the view
// hierarchy IS the tree (FR-3 groundwork).

enum FocusDirection {
    case left, right, up, down
}

final class TerminalWindowController: NSResponder, LocalProcessTerminalViewDelegate {
    private unowned let app: MemtermAppDelegate
    /// The window host currently displaying (or holding) this tab.
    weak var host: WindowHostController?
    /// The hosting window, while attached — kept as a computed property so
    /// the sheet/parenting and probe call sites read naturally.
    var window: NSWindow? { host?.window }
    /// Stable tab identity for the state store (one controller = one tab row).
    let tabId = UUID().uuidString
    /// FR-49: the workspace this tab belongs to (exactly one at a time;
    /// FR-58's "Move Tab to Workspace" / "New Workspace from Tab" reassign it
    /// through setWorkspace, never directly).
    private(set) var workspaceId: String

    /// FR-58: reassigns the tab to another workspace. Pure bookkeeping — the
    /// caller (MemtermAppDelegate.moveTab) handles host membership and the
    /// topology save that rewrites both workspaces' rows.
    func setWorkspace(_ id: String) {
        workspaceId = id
    }
    /// User-chosen tab name (double-click the tab body to set). While set, it
    /// pins the tab/window title — the automatic pane-title/cwd updates stop
    /// overwriting it. Persisted in the journal and restored (empty = auto).
    var customTitle: String? {
        didSet { refreshTitle() }
    }
    /// Founder 2026-08-31: per-tab color (hex), set via the tab's right-click
    /// menu. Rendered as the FULL tab tint in the strip (the founder's
    /// explicit ask — the attributed-title pill was the native-tab stand-in),
    /// journaled and restored.
    var tabColor: String? {
        didSet {
            host?.tabChanged(self)
            app.memory?.scheduleTopologySave()
        }
    }
    /// The strip label / window title for this tab.
    private(set) var displayTitle = "memterm"
    private weak var focusedPane: PaneView?
    /// The tab's pane-tree root container. Retained here so the views (and
    /// their ptys/processes) stay alive while the tab is deselected and the
    /// container is detached from any window.
    let paneRoot = NSView()
    /// Per-tab activity state (spinner while output flows on a non-selected
    /// tab, decaying to an unseen-output dot; TabActivity.swift). The strip
    /// renders it via the host.
    private var activity = TabActivityTracker()
    private var activityRefreshWork: DispatchWorkItem?
    /// ExtensionKit ui.setBadge: an extension-driven mark rendered through
    /// the SAME indicator slot. Real pty activity always outranks it; the
    /// extension owns clearing it (selection clears pty marks, not badges).
    private var extensionBadge: TabActivityState = .idle

    /// `initialCwd`: where the first pane's shell starts (nil = home). ⌘T/⌘N
    /// pass the key pane's kernel-truth cwd here when `new_tab_same_cwd` is on
    /// (iTerm2's "reuse previous session's directory"); restore paths ignore
    /// it (each restored pane carries its own journaled cwd).
    /// `initialSerial` (feature/serial): the tab's root pane is a serial pane
    /// opened on this setup instead of a shell (Shell ▸ New Serial
    /// Connection…). Mutually exclusive with restoredTab/initialCwd.
    init(app: MemtermAppDelegate, workspaceId: String = StateStore.defaultWorkspaceId,
         restoredTab: TabRestore? = nil,
         initialCwd: String? = nil, initialSerial: SerialPaneView.Setup? = nil) {
        self.app = app
        self.workspaceId = workspaceId
        super.init()
        // Pre-attach bounds so the initial pane/split tree is built against a
        // realistic size (the host swaps in the real container bounds on
        // select).
        paneRoot.frame = NSRect(x: 0, y: 0, width: 980, height: 584)
        paneRoot.autoresizesSubviews = true
        // Council #3: terminal content (live + ghost) gets breathing room
        // from the window edges — the whole tree sits inset inside paneRoot
        // (autoresizing keeps the margins fixed through resizes), the margin
        // shows the window's theme background, and split dividers inside the
        // tree stay flush and correct.
        let contentFrame = paneRoot.bounds.insetBy(dx: SplitLayout.contentInset,
                                                   dy: SplitLayout.contentInset)
        let root: NSView
        if let restoredTab {
            root = buildNode(restoredTab.tree, frame: contentFrame,
                             panes: restoredTab.panes)
        } else if let initialSerial {
            root = makeSerialPane(frame: contentFrame, setup: initialSerial,
                                  connectNow: true)
        } else {
            // A vanished inherited cwd falls back like a restore would —
            // never a broken pane (FR-25 spirit).
            let cwd = initialCwd.map { CwdFallback.resolve($0).path }
            root = makePane(frame: contentFrame, cwd: cwd)
        }
        root.frame = contentFrame
        root.autoresizingMask = [.width, .height]
        paneRoot.addSubview(root)
        if let restoredTab, !restoredTab.title.isEmpty {
            // Only custom names are journaled (auto titles regenerate live).
            customTitle = restoredTab.title
        }
        if let restoredTab, let color = restoredTab.color, !color.isEmpty {
            tabColor = color
        }
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Close / teardown (FR-56: memory follows intent)

    /// The old windowWillClose inference, now an explicit helper: a close is a
    /// user gesture only when the app isn't quitting, no workspace switch /
    /// park / forget is tearing windows down, and the tab is in the ACTIVE
    /// workspace (FR-59: a hidden workspace's tab has no on-screen UI — no
    /// user gesture can close it).
    func inferUserInitiatedClose() -> Bool {
        !app.isTerminating && !app.isSwitchingWorkspaces
            && workspaceId == app.activeWorkspaceId
    }

    /// Close this tab through its host (strip ✕, context-menu Close, smoke's
    /// FR-56 leg, park/forget teardown — the flags make the intent).
    func close() {
        if let host {
            host.close(tab: self, userInitiated: inferUserInitiatedClose())
        } else {
            teardown(userInitiated: inferUserInitiatedClose())
        }
    }

    /// A user's TAB-close gesture — the hover ✕ and the tab menu's Close Tab
    /// (founder ask 2026-09-09). With confirm_close_tab on, a window sheet
    /// asks first; its "Don't ask me again" box turns the setting off (saved
    /// to config.toml, mirrored by Settings) — honored only when the user
    /// actually closes, so a Cancel never silently changes a setting. The
    /// close itself is the unchanged FR-56 archive path. Council #1: a
    /// sheet on the host window, never a screen-centered runModal.
    func requestUserClose() {
        guard app.config.confirmCloseTab, let window = host?.window else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close “\(displayTitle)”?"
        alert.informativeText = "Its shells will be terminated. The scrollback is filed in the timeline archive."
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask me again"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on {
                self.app.setConfirmCloseTab(false)
            }
            // Deferred: the sheet is still winding down inside its own
            // completion; closing the tab (and maybe its window) from here
            // raced AppKit's sheet teardown.
            DispatchQueue.main.async { self.close() }
        }
    }

    /// Set just before close() when the ROOT pane's shell died on its own
    /// (processTerminated) so teardown archives with the honest close_reason.
    private var teardownCloseReason: SessionCloseReason?

    /// Kills the tab's panes and (only for a user gesture) ARCHIVES its
    /// journal rows + scrollback bytes into the timeline (founder-amended
    /// FR-56: closing files a memory instead of burning it — the tab still
    /// never restores). Every close path funnels here with explicit intent —
    /// quit is "put it down", close is "archive it", crash runs nothing at
    /// all; the EXPLICIT Forget gestures remain true deletion elsewhere.
    func teardown(userInitiated: Bool) {
        activityRefreshWork?.cancel()
        activityRefreshWork = nil
        let panes = allPanes()
        for pane in panes {
            pane.processDelegate = nil
            app.claudeClaims.release(paneId: pane.paneId)
            (pane as? SerialPaneView)?.shutdown()
            if pane.process.running { pane.terminate() }
        }
        app.controllerClosed(self)
        if userInitiated {
            // Immediate archive (row + file moves) and live-row cleanup: the
            // closed tab must never restore, even if the app dies before the
            // next debounced topology save runs — and its bytes must already
            // be safe in the archive.
            app.memory?.archiveTab(tabId: tabId, panes: panes,
                                   reason: teardownCloseReason ?? .userClose)
        }
        app.memory?.scheduleTopologySave()
        // FR-59 corollary: never leave the app windowless while other
        // workspaces hold hidden live tabs — surface the MRU one.
        app.activeWorkspaceWindowClosed(workspaceId, userInitiated: userInitiated)
        // Founder (stage 2): a USER close that empties a non-Default
        // workspace removes the workspace itself — Default persists.
        if userInitiated {
            app.workspaceEmptiedByUserClose(workspaceId)
        }
        // ExtensionKit events: the tab is gone (any teardown intent).
        app.extensionRuntime?.emit(.tabClosed, tab: TabRef(tabId: tabId))
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

        // feature/serial: line control + lenses, grouped under one submenu.
        if let serial = pane as? SerialPaneView {
            let serialItem = NSMenuItem(title: "Serial", action: nil, keyEquivalent: "")
            serialItem.submenu = makeSerialSubmenu(for: serial)
            menu.addItem(serialItem)
            menu.addItem(.separator())
        }

        // FR-58: creating a workspace must be reachable by right-click alone.
        let workspaceItem = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        workspaceItem.submenu = app.makeWorkspaceContextMenu(for: self)
        menu.addItem(workspaceItem)
        menu.addItem(.separator())
        add("Close Pane", #selector(ctxClosePane(_:)), target: self, represented: pane)
        return menu
    }

    /// feature/serial: the pane's Serial submenu. Built fresh per click so the
    /// line-state checkmarks and connect state are live. On a device with no
    /// modem lines (ENOTTY) the line items degrade to disabled, never guess.
    private func makeSerialSubmenu(for pane: SerialPaneView) -> NSMenu {
        let menu = NSMenu(title: "Serial")

        func add(_ title: String, _ action: Selector?, checked: Bool = false,
                 enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: enabled ? action : nil,
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = pane
            item.state = checked ? .on : .off
            menu.addItem(item)
        }

        let statusPrefix = pane.isConnected ? "Connected"
            : pane.awaitingDeviceReturn ? "Reconnecting when the device returns"
            : "Not connected"
        let status = NSMenuItem(title: "\(statusPrefix) — \(pane.setup.offer.displayName)",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        // Disconnect/Connect toggle (founder disconnect/connect stage): the
        // title flips with state. Disconnect is the deliberate port RELEASE
        // (flashing tools can take the device; hotplug auto-reopen is
        // suppressed); Connect reopens with the CURRENT settings.
        add(pane.isConnected ? "Disconnect" : "Connect",
            #selector(ctxSerialToggleConnection(_:)))
        menu.addItem(.separator())

        if pane.isConnected {
            let lines = pane.currentModemLines()
            add("Toggle DTR" + (lines.map { $0.dtr ? " (asserted)" : " (deasserted)" } ?? ""),
                #selector(ctxSerialToggleDTR(_:)), checked: lines?.dtr == true,
                enabled: lines != nil)
            add("Toggle RTS" + (lines.map { $0.rts ? " (asserted)" : " (deasserted)" } ?? ""),
                #selector(ctxSerialToggleRTS(_:)), checked: lines?.rts == true,
                enabled: lines != nil)
            if lines == nil {
                let note = NSMenuItem(title: "No modem lines on this device",
                                      action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
            add("Send Break", #selector(ctxSerialBreak(_:)))
            add("Reset Board (EN pulse)", #selector(ctxSerialReset(_:)),
                enabled: lines != nil)
            menu.addItem(.separator())
            add("Send Hex…", #selector(ctxSerialSendHex(_:)))
        } else {
            // While the device-vanished arm is standing, the user can cancel
            // it: a flasher's re-enumeration must not hand the port back
            // behind their back (performDisconnectGesture handles the
            // reconnectingAfterLoss cancel — the machine's userDisconnect).
            if pane.awaitingDeviceReturn {
                add("Stop Auto-Reconnect", #selector(ctxSerialStopAutoReconnect(_:)))
            }
            add("Reconnect (⌘R)", #selector(ctxSerialReconnect(_:)))
        }
        add("Hex View", #selector(ctxSerialHexView(_:)), checked: pane.hexMode)
        return menu
    }

    @objc private func ctxSerialToggleDTR(_ sender: NSMenuItem) {
        (sender.representedObject as? SerialPaneView)?.toggleDTR()
    }

    @objc private func ctxSerialToggleRTS(_ sender: NSMenuItem) {
        (sender.representedObject as? SerialPaneView)?.toggleRTS()
    }

    @objc private func ctxSerialBreak(_ sender: NSMenuItem) {
        (sender.representedObject as? SerialPaneView)?.sendBreakSignal()
    }

    @objc private func ctxSerialReset(_ sender: NSMenuItem) {
        (sender.representedObject as? SerialPaneView)?.resetBoard()
    }

    @objc private func ctxSerialReconnect(_ sender: NSMenuItem) {
        (sender.representedObject as? SerialPaneView)?.performReconnectGesture()
    }

    @objc private func ctxSerialToggleConnection(_ sender: NSMenuItem) {
        (sender.representedObject as? SerialPaneView)?.toggleConnectionGesture()
    }

    @objc private func ctxSerialStopAutoReconnect(_ sender: NSMenuItem) {
        (sender.representedObject as? SerialPaneView)?.performDisconnectGesture()
    }

    @objc private func ctxSerialHexView(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? SerialPaneView else { return }
        pane.setHexMode(!pane.hexMode)
    }

    @objc private func ctxSerialSendHex(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? SerialPaneView else { return }
        promptSendHex(for: pane)
    }

    /// "Send Hex…": one field, parsed by SerialHex.parseInput (forgiving —
    /// "DE AD", "0xde,0xad", "dead" all work); what was sent echoes as a dim
    /// line in the pane. Sheet on the HOST window, matching the rename pattern.
    func promptSendHex(for pane: SerialPaneView) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Send Hex Bytes"
        alert.informativeText = "e.g. “DE AD BE EF”, “0x01,0x02”, or “deadbeef”. Sent raw — no line ending appended."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "DE AD BE EF"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak pane] response in
            guard response == .alertFirstButtonReturn, let pane else { return }
            guard let bytes = SerialHex.parseInput(field.stringValue), !bytes.isEmpty else {
                pane.feedDim("memterm: not valid hex: \(field.stringValue)")
                return
            }
            pane.writeRaw(bytes)
        }
        alert.window.makeFirstResponder(field)
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

    private func terminalOptions() -> TerminalOptions {
        TerminalOptions(cursorStyle: app.config.terminalCursorStyle,
                        scrollback: app.config.scrollbackLines)
    }

    private func constructPane(frame: NSRect) -> PaneView {
        let pane = PaneView(frame: frame, font: app.currentFont(),
                            options: terminalOptions())
        stylePane(pane)
        return pane
    }

    /// feature/serial: a pane whose byte source is a SerialConnection.
    /// Identical chrome/config to a shell pane; `connectNow` opens the device
    /// immediately (the caller's Connect click IS the consent gesture) and
    /// surfaces a failure as a dim line + pending ⌘R retry, never an alert.
    func makeSerialPane(frame: NSRect, setup: SerialPaneView.Setup,
                        connectNow: Bool) -> SerialPaneView {
        let pane = SerialPaneView(setup: setup, frame: frame, font: app.currentFont(),
                                  options: terminalOptions())
        stylePane(pane)
        pane.onSerialStateChanged = { [weak self, weak pane] in
            if let pane { self?.refreshTitle(for: pane) }
        }
        if connectNow {
            pane.feedDim("memterm: serial \(setup.offer.displayName) (\(setup.path))")
            do {
                try pane.connect()
            } catch {
                pane.pendingReconnectOffer = true
                pane.feedDim("memterm: could not open \(setup.path) (\(SerialPaneView.describe(error))) — press ⌘R to retry")
            }
        }
        app.ensureSerialHotplug()
        return pane
    }

    private func stylePane(_ pane: PaneView) {
        let config = app.config
        pane.autoresizingMask = [.width, .height]
        pane.copyOnSelect = config.copyOnSelect
        pane.optionAsMetaKey = config.optionAsMeta
        pane.bellStyle = config.terminalBellStyle
        pane.bellSoundName = config.bellSound
        // SCROLL UX: the config intent, not SwiftTerm's raw flag — the pane
        // derives allowMouseReporting from intent AND live mouseMode so
        // streaming output cannot clear a selection (see PaneView).
        pane.mouseReportingConfigured = config.allowMouseReporting
        if config.lineSpacing != 1.0 { pane.lineSpacing = CGFloat(config.lineSpacing) }
        pane.processDelegate = self
        // Transparency lives in the WINDOW's background (applyWindowChrome
        // paints the theme ground at window_opacity), never window alpha —
        // text stays fully opaque. The pane's own default background is
        // fully clear under translucency: founder bug 2026-09-09 ("this
        // weird bar or border around the whole text area") was the pane
        // painting the same ground at the same alpha AGAIN over the window's,
        // so the council-#3 9pt margin (one layer) read lighter than the
        // pane body (two layers). RGB is kept (alpha 0, not .clear) so the
        // engine's default-background color — reverse video, OSC 11 — stays
        // the theme color.
        if let bg = config.themeBackgroundColor {
            pane.nativeBackgroundColor = config.isWindowOpaque
                ? bg : bg.withAlphaComponent(0)
        } else if !config.isWindowOpaque {
            pane.nativeBackgroundColor = NSColor.black.withAlphaComponent(0)
        }
        // Founder 2026-09-09 ("why does the black background stand out so
        // much"): explicit cell backgrounds (Claude Code's prompt rows, diff
        // lines) follow the window opacity like iTerm2, instead of
        // Terminal.app's solid blocks. Our fork of SwiftTerm carries the knob.
        pane.translucentCellBackgrounds = true
        if let fg = config.themeForegroundColor { pane.nativeForegroundColor = fg }
        if let cursor = config.themeCursorColor { pane.caretColor = cursor }
        if let selection = config.themeSelectionColor {
            pane.selectedTextBackgroundColor = selection
        }
        if let ansi = config.terminalAnsiColors { pane.installColors(ansi) }
        pane.onOutputActivity = { [weak self] in self?.paneProducedOutput() }
        pane.onBell = { [weak self] in self?.paneRangBell() }
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
    /// host. An un-hosted tab (mid-construction/re-homing) counts as selected.
    private var isSelectedTab: Bool {
        guard let host else { return true }
        return host.selectedTab === self
    }

    /// Called from PaneView.dataReceived (main thread — LocalProcess delivers
    /// on DispatchQueue.main). Coalesced by the tracker to ≤1 UI update per
    /// 250 ms per tab, so flood output never churns the strip.
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

    /// The host selected this tab (or its window became key): everything is
    /// seen, the mark clears.
    func noteSelected() {
        activity.recordSelected()
        refreshActivityIndicator()
    }

    private func refreshActivityIndicator() {
        activityRefreshWork?.cancel()
        activityRefreshWork = nil
        let now = ProcessInfo.processInfo.systemUptime
        host?.tabChanged(self)
        // While active, one more repaint just past the decay boundary flips
        // the spinner to the solid unseen-output dot.
        if let decayAt = activity.nextDecay(after: now) {
            scheduleActivityRefresh(after: decayAt - now + 0.05)
        }
    }

    /// MEMTERM_UI_PROBE support (and the strip's render source): the
    /// tracker's current state, merged with any extension badge (pty
    /// activity outranks; the default .idle badge changes nothing).
    func activityStateForProbe() -> TabActivityState {
        let tracked = activity.state(at: ProcessInfo.processInfo.systemUptime)
        if tracked == .active || extensionBadge == .active { return .active }
        if tracked == .unseen || extensionBadge == .unseen { return .unseen }
        return .idle
    }

    /// ExtensionKit ui.setBadge (via ExtensionHostRuntime).
    func setExtensionBadge(_ state: TabActivityState) {
        extensionBadge = state
        host?.tabChanged(self)
    }

    /// Probe seam: the raw extension badge, un-merged (pty activity would
    /// mask it in activityStateForProbe on a tab that just produced output).
    func extensionBadgeForProbe() -> TabActivityState { extensionBadge }

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
            let split = ThemedSplitView(frame: frame)
            split.themeDividerColor = ThemedSplitView.resolvedDividerColor(app.config)
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

    /// Ghost scrollback + restored divider, shared by shell and serial
    /// restores. feed() only — nothing here ever reaches a pty or a device.
    /// Council #9: stacked divider generations inside the ghost (relaunch
    /// piles) are collapsed to one honest line before feeding — the pure
    /// logic (and its searchability contract) lives in ScrollbackText.
    private func feedRestoredPreamble(into pane: PaneView, paneId: String) {
        if let ghost = app.memory?.loadScrollback(for: paneId), !ghost.isEmpty {
            let collapsed = ScrollbackText.collapseRestoredDividers(ghost)
            let crlf = ScrollbackText.ghostFeedText(collapsed)
            pane.feed(text: "\u{1b}[2m" + crlf + "\u{1b}[0m\r\n")
        }
        let stamp = Self.restoreDateFormatter.string(from: Date())
        let divider = ScrollbackText.restoredDividerLine(stamp: stamp)
        pane.feed(text: "\u{1b}[36m\(divider)\u{1b}[0m\r\n")
        pane.restoredDividerCount += 1
    }

    /// feature/serial restore: serial sessions are RECONNECTABLE. The pane
    /// comes back with its ghost scrollback and the standard consent-gated
    /// offer — the device is NEVER opened here; only the ⌘R gesture (a
    /// reconnect action, not a typed command) opens it.
    private func makeRestoredSerialPane(frame: NSRect, id: String,
                                        offer: SerialAdapter.ReconnectOffer) -> SerialPaneView {
        let setup = SerialPaneView.Setup(path: offer.path, identity: offer.identity,
                                         label: offer.label, settings: offer.settings,
                                         txLineEnding: offer.txLineEnding,
                                         localEcho: offer.localEcho)
        let pane = makeSerialPane(frame: frame, setup: setup, connectNow: false)
        pane.paneId = id
        pane.cwdSource = "restore"
        feedRestoredPreamble(into: pane, paneId: id)
        pane.pendingReconnectOffer = true
        pane.feed(text: "\u{1b}[36mmemterm: was connected: \(offer.displayName) — press ⌘R to reconnect\u{1b}[0m\r\n")
        return pane
    }

    private func makeRestoredPane(frame: NSRect, id: String, restore: PaneRestore?) -> PaneView {
        if let snap = restore?.snapshot, snap.adapter == SerialAdapter.name,
           let offer = SerialAdapter.reconnectOffer(from: snap.adapterState) {
            return makeRestoredSerialPane(frame: frame, id: id, offer: offer)
        }
        let (cwd, fellBack) = CwdFallback.resolve(restore?.cwd)
        let pane = constructPane(frame: frame)
        pane.paneId = id
        pane.lastKnownCwd = cwd
        pane.cwdSource = "restore"
        feedRestoredPreamble(into: pane, paneId: id)
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
        guard let root = paneRoot.subviews.first,
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

    /// Walks the tab's OWN pane tree (works while the tab is deselected and
    /// its root view is detached from any window).
    func allPanes() -> [PaneView] {
        var result: [PaneView] = []
        func walk(_ view: NSView) {
            if let pane = view as? PaneView { result.append(pane); return }
            view.subviews.forEach(walk)
        }
        walk(paneRoot)
        return result
    }

    /// Every split in this tab's tree (council #8: divider re-theming, and
    /// the probe's divider-contrast leg).
    func allSplitViews() -> [ThemedSplitView] {
        var result: [ThemedSplitView] = []
        func walk(_ view: NSView) {
            if let split = view as? ThemedSplitView { result.append(split) }
            if view is PaneView { return }
            view.subviews.forEach(walk)
        }
        walk(paneRoot)
        return result
    }

    /// MEMTERM_UI_PROBE diagnostics: one-line-per-node dump of the pane tree
    /// (type, frame, hidden, window attachment) — the close-pane leg prints
    /// it so a "blanked tab" failure shows the surviving hierarchy.
    func probeTreeDump() -> String {
        var lines: [String] = []
        func walk(_ view: NSView, depth: Int) {
            let indent = String(repeating: "  ", count: depth)
            let kind: String
            if let pane = view as? PaneView {
                kind = "pane(\(pane.paneId.prefix(8)))"
            } else if let split = view as? NSSplitView {
                kind = "split(\(split.isVertical ? "v" : "h") arranged=\(split.arrangedSubviews.count))"
            } else {
                kind = String(describing: type(of: view))
            }
            let f = view.frame
            lines.append("\(indent)\(kind) frame=\(Int(f.origin.x)),\(Int(f.origin.y)),\(Int(f.width))x\(Int(f.height)) hidden=\(view.isHidden) inWindow=\(view.window != nil)")
            for sub in view.subviews where sub is PaneView || sub is NSSplitView {
                walk(sub, depth: depth + 1)
            }
        }
        walk(paneRoot, depth: 0)
        return lines.joined(separator: "\n")
    }

    func currentPane() -> PaneView? {
        if let pane = window?.firstResponder as? PaneView,
           allPanes().contains(where: { $0 === pane }) { return pane }
        if let pane = focusedPane { return pane }
        return allPanes().first
    }

    /// Called by the host's firstResponder KVO when a pane of THIS tab took
    /// focus (the observation lives on the host window now).
    func paneFocused(_ pane: PaneView) {
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
        let split = ThemedSplitView(frame: oldFrame)
        split.themeDividerColor = ThemedSplitView.resolvedDividerColor(app.config)
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
        // ⌘W on the tab's LAST pane closes the whole tab — that is a tab
        // close, so it asks like the ✕ does (confirm_close_tab; founder
        // 2026-09-09). On a split it just closes the pane, no question.
        if allPanes().count == 1 {
            requestUserClose()
            return
        }
        close(pane: pane)
    }

    func close(pane: PaneView, reason: SessionCloseReason = .userClose) {
        pane.processDelegate = nil
        app.claudeClaims.release(paneId: pane.paneId)
        (pane as? SerialPaneView)?.shutdown()  // serial fd, no process to kill
        if pane.process.running { pane.terminate() }

        guard let split = pane.superview as? NSSplitView else {
            // Root (only) pane: close the tab (FR-56 discrimination is the
            // explicit userInitiated parameter now; the inference matches the
            // old windowWillClose exactly). The reason rides along so a shell
            // exiting archives as shell-exited, not user-close.
            teardownCloseReason = reason
            close()
            return
        }
        // FR-56 (amended): a user-initiated pane close ARCHIVES that pane NOW
        // — journal row into sessions, scrollback + .hist moved into the
        // timeline archive. Quit/park teardown never reaches here (teardown
        // detaches processDelegate before terminating), but the flags guard
        // it anyway. FR-59: a pane in a HIDDEN workspace can only get here
        // via processTerminated (its shell died on its own) — no user
        // gesture is possible there, so it never archives (its rows keep and
        // the pane restores, exactly as before this train).
        if inferUserInitiatedClose() {
            app.memory?.archivePane(pane, reason: reason)
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
        paneRoot.needsLayout = true
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
            // REAL BUG (probe-caught by the council-#8 divider leg, 2026-09-02):
            // NSSplitView flips arranged subviews to constraint-based layout
            // (translatesAutoresizingMaskIntoConstraints = false). A pane
            // unwrapped back into the frame/autoresizing world must flip BACK,
            // or any internal constraints it carries (the ⌘F find bar's) size
            // the PANE at the next layout pass — probe-observed as a 962x566
            // pane collapsing to 378x0 the moment a sheet opened.
            new.translatesAutoresizingMaskIntoConstraints = true
            parent.replaceSubview(old, with: new)
        }
    }

    // MARK: - Focus movement (⌘⌥ arrows): nearest pane center in the direction.

    func moveFocus(_ direction: FocusDirection) {
        guard let current = currentPane(), let window else { return }
        let panes = allPanes().filter { $0 !== current }
        guard !panes.isEmpty else { return }

        func center(_ v: NSView) -> NSPoint {
            let r = v.convert(v.bounds, to: paneRoot)
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

    /// Live theme application from the Settings window — the PANE share.
    /// (Window-level chrome — background, opacity, blur — moved to
    /// WindowHostController.applyWindowChrome.) Explicit defaults are pushed
    /// when the theme is cleared so panes don't keep stale colors.
    func applyTheme(_ config: Config) {
        // Council #8: dividers follow the theme live, same floor as at build.
        let dividerColor = ThemedSplitView.resolvedDividerColor(config)
        for split in allSplitViews() {
            split.themeDividerColor = dividerColor
        }
        let opaque = config.isWindowOpaque
        let bg = config.themeBackgroundColor ?? .black
        let fg = config.themeForegroundColor
            ?? NSColor(srgbRed: 0.77, green: 0.78, blue: 0.78, alpha: 1)
        for pane in allPanes() {
            pane.copyOnSelect = config.copyOnSelect
            pane.optionAsMetaKey = config.optionAsMeta
            pane.bellStyle = config.terminalBellStyle
            pane.bellSoundName = config.bellSound
            pane.mouseReportingConfigured = config.allowMouseReporting
            // Live cursor restyle (Terminal.setCursorStyle is public —
            // verified in SwiftTerm's Terminal.swift:4123).
            pane.getTerminal().setCursorStyle(config.terminalCursorStyle)
            // Translucency is the window's; the pane ground is clear (see
            // constructPane — the founder's 2026-09-09 margin seam).
            pane.nativeBackgroundColor = opaque ? bg : bg.withAlphaComponent(0)
            pane.translucentCellBackgrounds = true
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

    /// Recomputes displayTitle (customTitle pins; else pane OSC title, else
    /// ~-abbreviated cwd, else "memterm") and reports it upward — the host
    /// syncs window.title and the strip label.
    private func refreshTitle() {
        if let customTitle {
            displayTitle = customTitle
        } else if let pane = currentPane(), !pane.paneTitle.isEmpty {
            displayTitle = pane.paneTitle
        } else if let dir = currentPane()?.currentLocalDirectory {
            displayTitle = (dir as NSString).abbreviatingWithTildeInPath
        } else {
            displayTitle = "memterm"
        }
        host?.tabChanged(self)
    }

    @objc func ctxSetTabColor(_ sender: NSMenuItem) {
        let hex = sender.representedObject as? String
        tabColor = (hex?.isEmpty ?? true) ? nil : hex
    }

    /// Double-click on the tab body (FR: founder request 2026-08-31). Empty
    /// input clears the custom name and automatic titles resume. Sheet on the
    /// HOST window.
    func promptRenameTab() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to go back to automatic titles."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = customTitle ?? ""
        field.placeholderString = displayTitle
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
        // FR-56 (amended): a shell dying on its own archives too — the
        // close_reason column tells it apart from a user gesture.
        close(pane: pane, reason: .shellExited)
    }
}

/// Council #8: a split view whose divider color derives from the THEME with
/// a contrast floor (ChromeContrast.dividerColor, L2-tested) — the system
/// separator vanished into dark terminal backgrounds. The color is pushed at
/// construction and again by applyTheme on every live theme change.
final class ThemedSplitView: NSSplitView {
    var themeDividerColor: NSColor = .separatorColor {
        didSet { needsDisplay = true }
    }

    override var dividerColor: NSColor { themeDividerColor }

    /// Deterministic divider paint: AppKit's .thin divider drawing skipped
    /// our color on this macOS (probe-verified: divider pixels sampled
    /// identical to the pane ground) — fill the divider rect explicitly.
    override func drawDivider(in rect: NSRect) {
        themeDividerColor.setFill()
        rect.fill()
    }

    static func resolvedDividerColor(_ config: Config) -> NSColor {
        ChromeContrast.dividerColor(themeBackground: config.themeBackground).nsColor
    }
}

/// Chrome-row button whose right-click shows the menu its menuProvider
/// returns (FR-58) — the two Settings gears are its users. NSView's default
/// rightMouseDown displays whatever menu(for:) returns.
final class ChipButton: NSButton {
    var menuProvider: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    /// One Settings-gear setup for both homes (workspace-bar row, and the
    /// tab strip's fallback gear shown when that row is hidden): left-click
    /// opens Preferences, right-click pops the workspace switcher.
    func configureAsSettingsGear(app: MemtermAppDelegate) {
        menuProvider = { [weak app] in app?.makeWorkspacePopUpMenu() }
        isBordered = false
        setButtonType(.momentaryChange)
        image = NSImage(systemSymbolName: "gearshape",
                        accessibilityDescription: "Settings")
        contentTintColor = .secondaryLabelColor
        toolTip = "Settings (right-click: workspaces)"
        target = app
        action = #selector(MemtermAppDelegate.openPreferences(_:))
    }
}
