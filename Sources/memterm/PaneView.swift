import AppKit
import MemtermCore
import SwiftTerm

// One terminal pane: a LocalProcessTerminalView plus the Stage-1 UX behaviors
// (copy-on-select, middle-click paste, focus dimming) and per-pane state the
// window controller reads for titles and split inheritance.

class PaneView: LocalProcessTerminalView {
    var copyOnSelect = true
    var paneTitle = ""
    /// Local filesystem path from OSC 7, when the shell reports one.
    var currentLocalDirectory: String?

    // -- Memory engine state --
    /// Stable identity across relaunches; keys the panes table and scrollback file.
    var paneId = UUID().uuidString
    /// Best-known cwd: kernel truth when the poller has one, else OSC 7,
    /// seeded at spawn so a pre-poll topology save never writes NULL.
    var lastKnownCwd: String?
    var cwdSource = "spawn"
    /// The captured command ⌘R types into the pty (never executed — FR-29).
    var pendingResumeCommand: String?
    /// Stage 3 (claude-browser badges): the session id of the claude this
    /// pane's foreground process classified as, kept current by
    /// MemoryEngine.pollPane (nil whenever the fg process is not claude).
    /// Read by ExtensionHostRuntime.claudeTabSessions().
    var lastClaudeSessionId: String?
    /// FR-59 guard rail: how many "── restored ──" dividers were ever fed into
    /// this pane. The resurrect path increments it; a workspace switch must
    /// not (switching is hide/show, never restore) — the smoke gate asserts
    /// this stays 0 across a switch round-trip.
    var restoredDividerCount = 0
    /// Shell executable this pane spawned; restored panes respawn the same one.
    var shellPath: String?
    /// Set by the host controller: pty output arrived (tab activity
    /// indicator). Fired from dataReceived on the main thread; the controller
    /// coalesces, so this stays cheap per chunk.
    var onOutputActivity: (() -> Void)?
    /// Set by the host controller: BEL arrived. Fired after super applied the
    /// configured bellStyle (sound/visual/none — SwiftTerm handles those); the
    /// controller adds the app-level responses (tab dot, dock attention).
    var onBell: (() -> Void)?
    /// `bell_sound`: a named macOS sound replacing the default system beep.
    /// nil keeps SwiftTerm's delegate default (NSSound.beep()).
    var bellSoundName: String?

    // -- SCROLL UX: selection survives scroll --
    /// The user's `allow_mouse_reporting` config intent. SwiftTerm's own
    /// `allowMouseReporting` flag DOUBLES as "clear the native selection on
    /// every output chunk" (AppleTerminalView.feedPrepare — internal, not
    /// overridable — and MacTerminalView.linefeed both call selectNone
    /// whenever it is true, verified in SwiftTerm 1.20.0). That was the
    /// founder bug "selecting text loses selection when output scrolls":
    /// with the flag at its default, ANY streaming output killed the
    /// selection, even with no app tracking the mouse. The view-level flag
    /// is therefore DERIVED, never set directly:
    ///     allowMouseReporting = configured && terminal.mouseMode != .off
    /// Every SwiftTerm mouse-forwarding site tests
    /// `allowMouseReporting && mouseMode.sendXxx()`, so routing to vim/htop
    /// is unchanged the moment they enable tracking. `mouseMode` only
    /// mutates while bytes are parsed, and every byte path into a pane is
    /// ours (dataReceived below; SerialPaneView.ingest), so syncing on both
    /// sides of each feed holds the invariant everywhere. The Terminal layer
    /// already anchors selections to buffer content
    /// (SelectionScrollAnchoringTests); this makes that anchoring reach the
    /// screen.
    var mouseReportingConfigured = true {
        didSet { syncAllowMouseReporting() }
    }

    func syncAllowMouseReporting() {
        let effective = MouseReportingPolicy.effectiveAllowMouseReporting(
            configured: mouseReportingConfigured,
            mouseModeActive: getTerminal().mouseMode != .off)
        if allowMouseReporting != effective { allowMouseReporting = effective }
    }

    // -- SCROLL UX: overlay scrollbar --
    /// The auto-hiding per-pane scroll band (OverlayScrollerView.swift).
    /// Installed lazily on first superview attach; serial panes inherit it.
    private(set) var scrollerOverlay: OverlayScrollerView?
    /// Space reserved at the pane's bottom edge (the serial footer bar) that
    /// the scroll band must not cover.
    var scrollerBottomInset: CGFloat = 0 {
        didSet { scrollerOverlay?.bottomInset = scrollerBottomInset }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installScrollUXIfNeeded()
    }

    private func installScrollUXIfNeeded() {
        guard scrollerOverlay == nil, superview != nil else { return }
        // Retire SwiftTerm's built-in NSScroller: as a STANDALONE overlay
        // scroller it never flashes on scroll activity, and its .knobSlot
        // (click-to-page) case is unimplemented upstream — while it still
        // reserves a right-edge gutter (reservedScrollerWidth goes to 0 once
        // it is hidden; verified in MacTerminalView.swift). The overlay band
        // replaces it without costing columns.
        // Hidden first (reservedScrollerWidth keys off isHidden), then OUT of
        // the tree: a dead hidden view whose constraints anchor to the pane
        // is pointless layout-engine load. (Note: removing it does NOT cure
        // the quiet-probe stale-frame quirk — see
        // ProbeLegs.probeRepairPaneFrame — window-level autolayout manages
        // pane frames regardless; this removal is cleanup, not the fix.)
        for sub in subviews where sub is NSScroller {
            sub.isHidden = true
            sub.removeFromSuperview()
        }
        let overlay = OverlayScrollerView()
        overlay.pane = self
        overlay.bottomInset = scrollerBottomInset
        addSubview(overlay)
        overlay.updateFrameToBand()
        scrollerOverlay = overlay
        // Recompute cols against the reclaimed gutter width — DEFERRED:
        // viewDidMoveToSuperview fires inside addSubview, possibly inside a
        // layout pass, and a reentrant setFrameSize there corrupts the
        // layout engine's frame bookkeeping for reparented panes.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.setFrameSize(self.frame.size)
        }
    }

    /// TerminalViewDelegate scroll tick (LocalProcessTerminalView routes it
    /// here; open — verified). Fires for BOTH user scrolls (wheel/keyboard →
    /// scrollTo) and output-driven scrolling, per scrolled line during
    /// floods — noteScrollActivity is O(1)-cheap by contract.
    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        scrollerOverlay?.noteScrollActivity()
    }

    // -- Search state (FR-4, plumbing in FindBar.swift) --
    /// This pane's ⌘F find bar, created lazily on first use.
    var findBar: PaneFindBar?
    /// Set while search moves the selection to highlight a match, so
    /// copy-on-select doesn't clobber the clipboard on every jump.
    var searchIsDrivingSelection = false

    /// Whole buffer (scrollback + visible grid) as plain text, wrapped rows
    /// re-joined, trailing blank grid rows trimmed, capped to maxLines
    /// (assembly logic lives in MemtermCore.ScrollbackText).
    ///
    /// ENGINE SEAM: this method is the single SwiftTerm-facing capture surface
    /// for persistence (see the seam-status note in TerminalEngine.swift).
    /// Never let MemoryEngine/StateStore reach into SwiftTerm buffer types
    /// anywhere else.
    func scrollbackText(maxLines: Int) -> String {
        let terminal = getTerminal()
        var rows: [ScrollbackText.Row] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            rows.append(ScrollbackText.Row(text: line.translateToString(trimRight: true),
                                           isWrapped: line.isWrapped))
            row += 1
        }
        return ScrollbackText.assemble(rows: rows, maxLines: maxLines)
    }
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if copyOnSelect, !searchIsDrivingSelection, let text = getSelection(), !text.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    /// FR-58: right-click context menu. SwiftTerm's MacTerminalView overrides
    /// neither rightMouseDown nor menu(for:) (verified by grep — right-clicks
    /// never reach the pty, even under mouse reporting), so this override
    /// replaces nothing. The host window controller builds the menu because it
    /// owns splits, workspaces, and memory actions.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let host = window?.delegate as? WindowHostController,
              let controller = host.tab(containing: self) else {
            return super.menu(for: event)
        }
        return controller.contextMenu(for: self)
    }

    /// Founder UX: live tab-activity marks. LocalProcess delivers pty data on
    /// DispatchQueue.main (its default dispatchQueue — verified in
    /// LocalProcess.swift), so this runs on the main thread; super parses the
    /// bytes into the terminal first.
    ///
    /// SCROLL UX: allowMouseReporting is synced on BOTH sides of the feed —
    /// before, so SwiftTerm's feed-time selection clears see the derived
    /// value (selection survives streaming output while no app tracks the
    /// mouse); after, so a mouse-mode change parsed from THIS chunk reaches
    /// event routing before the next click.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        syncAllowMouseReporting()
        super.dataReceived(slice: slice)
        syncAllowMouseReporting()
        onOutputActivity?()
    }

    /// BEL (0x07). super consults `bellStyle` (public var, default .sound —
    /// verified in MacTerminalView.swift:3357) for the in-view response; the
    /// hook lets the controller mark the tab and request dock attention.
    /// Overriding the open class method (not the TerminalViewDelegate default)
    /// keeps the dispatch real: LocalProcessTerminalView satisfies the
    /// delegate's bell via a protocol extension, which a subclass can't hook.
    override func bell(source: Terminal) {
        // Custom bell sound (`bell_sound`): the .sound half of bellStyle
        // normally dispatches to the TerminalViewDelegate default, which is
        // NSSound.beep() via a protocol extension — not overridable from
        // here (LocalProcessTerminalView is its own terminalDelegate). So
        // the sound half is suppressed for one dispatch (super still runs
        // the visual half) and the named sound plays instead.
        if let name = bellSoundName, let sound = NSSound(named: name),
           bellStyle == .sound || bellStyle == .soundAndVisual {
            let saved = bellStyle
            bellStyle = saved == .soundAndVisual ? .visual : .none
            super.bell(source: source)
            bellStyle = saved
            sound.stop()  // restart on rapid-fire BELs instead of dropping them
            sound.play()
        } else {
            super.bell(source: source)
        }
        onBell?()
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click paste, unless the program asked for mouse reporting.
        if event.buttonNumber == 2 && getTerminal().mouseMode == .off {
            paste(self)
            return
        }
        super.otherMouseDown(with: event)
    }

    func updateLocalDirectory(fromOSC7 directory: String?) {
        guard let directory else { return }
        if let url = URL(string: directory), url.isFileURL {
            currentLocalDirectory = url.path
        } else if directory.hasPrefix("/") {
            currentLocalDirectory = directory
        }
    }
}
