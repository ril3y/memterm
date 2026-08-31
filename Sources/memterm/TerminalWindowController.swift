import AppKit
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
    private weak var focusedPane: PaneView?
    // SwiftTerm's becomeFirstResponder is not open, so focus changes are
    // tracked by observing the window's firstResponder instead.
    private var firstResponderObservation: NSKeyValueObservation?

    init(app: MemtermAppDelegate, restoredTab: TabRestore? = nil, restoredFrame: NSRect? = nil) {
        self.app = app
        let rect = NSRect(x: 0, y: 0, width: 980, height: 640)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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
        if let bg = app.config.themeBackground { window.backgroundColor = bg }
        super.init(window: window)
        window.delegate = self
        firstResponderObservation = window.observe(\.firstResponder) { [weak self] window, _ in
            if let pane = window.firstResponder as? PaneView {
                self?.paneFocused(pane)
            }
        }

        let content = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        window.contentView = content
        let root: NSView
        if let restoredTab {
            root = buildNode(restoredTab.tree, frame: content.bounds, panes: restoredTab.panes)
        } else {
            root = makePane(frame: content.bounds, cwd: nil)
        }
        content.addSubview(root)
        if let first = allPanes().first {
            window.makeFirstResponder(first)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Panes

    private func makePane(frame: NSRect, cwd: String?) -> PaneView {
        let pane = constructPane(frame: frame)
        pane.lastKnownCwd = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        startShell(in: pane, cwd: cwd)
        return pane
    }

    private func constructPane(frame: NSRect) -> PaneView {
        let config = app.config
        let options = TerminalOptions(scrollback: config.scrollbackLines)
        let pane = PaneView(frame: frame, font: app.currentFont(), options: options)
        pane.autoresizingMask = [.width, .height]
        pane.copyOnSelect = config.copyOnSelect
        pane.processDelegate = self
        if let bg = config.themeBackground { pane.nativeBackgroundColor = bg }
        if let fg = config.themeForeground { pane.nativeForegroundColor = fg }
        if let cursor = config.themeCursor { pane.caretColor = cursor }
        if let ansi = config.ansiColors { pane.installColors(ansi) }
        return pane
    }

    private func startShell(in pane: PaneView, cwd: String?, shellOverride: String? = nil) {
        var shell = shellOverride ?? app.config.shell
            ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if !FileManager.default.isExecutableFile(atPath: shell) { shell = "/bin/zsh" }
        pane.shellPath = shell
        let shellName = (shell as NSString).lastPathComponent
        pane.startProcess(executable: shell, execName: "-\(shellName)", currentDirectory: cwd)
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
        let (cwd, fellBack) = MemoryEngine.resolveCwd(restore?.cwd)
        let pane = constructPane(frame: frame)
        pane.paneId = id
        pane.lastKnownCwd = cwd
        pane.cwdSource = "restore"

        // Ghost scrollback: history the user can scroll/search. feed() only —
        // nothing here ever reaches the pty.
        if let ghost = app.memory?.loadScrollback(for: id), !ghost.isEmpty {
            let crlf = ghost.replacingOccurrences(of: "\n", with: "\r\n")
            pane.feed(text: "\u{1b}[2m" + crlf + "\u{1b}[0m\r\n")
        }
        let stamp = Self.restoreDateFormatter.string(from: Date())
        pane.feed(text: "\u{1b}[36m── restored — \(stamp) ──\u{1b}[0m\r\n")
        if fellBack, let saved = restore?.cwd {
            pane.feed(text: "\u{1b}[2mmemterm: directory not available: \(saved)\u{1b}[0m\r\n")
        }
        if let snap = restore?.snapshot, !snap.adapter.isEmpty,
           let offer = Adapters.resumeOffer(for: snap) {
            pane.pendingResumeCommand = offer.command
            pane.feed(text: "\u{1b}[36mmemterm: was running \(offer.label) — press ⌘R to type: \(offer.command)\u{1b}[0m\r\n")
        }
        startShell(in: pane, cwd: cwd, shellOverride: restore?.shell)
        return pane
    }

    // MARK: - Capture (split tree snapshot for the state store)

    func snapshotTab() -> TabSnap? {
        guard let root = window?.contentView?.subviews.first,
              let tree = snapshotNode(root) else { return nil }
        let panes = allPanes().map {
            PaneSnap(id: $0.paneId, shell: $0.shellPath, cwd: $0.lastKnownCwd,
                     cwdSource: $0.cwdSource)
        }
        return TabSnap(id: tabId, title: window?.title ?? "", tree: tree, panes: panes)
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
        let newPane = makePane(frame: oldFrame, cwd: pane.currentLocalDirectory)
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

    private func close(pane: PaneView) {
        pane.processDelegate = nil
        if pane.process.running { pane.terminate() }

        guard let split = pane.superview as? NSSplitView else {
            // Root (only) pane: close the tab/window.
            window?.close()
            return
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
        }
        if let next = allPanes().first {
            window?.makeFirstResponder(next)
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

    private func refreshTitle(for pane: PaneView) {
        guard pane === currentPane() else { return }
        if !pane.paneTitle.isEmpty {
            window?.title = pane.paneTitle
        } else if let dir = pane.currentLocalDirectory {
            window?.title = (dir as NSString).abbreviatingWithTildeInPath
        } else {
            window?.title = "memterm"
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for pane in allPanes() {
            pane.processDelegate = nil
            if pane.process.running { pane.terminate() }
        }
        app.controllerClosed(self)
        app.memory?.scheduleTopologySave()
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
