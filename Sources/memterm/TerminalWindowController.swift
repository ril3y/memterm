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
    private weak var focusedPane: PaneView?
    // SwiftTerm's becomeFirstResponder is not open, so focus changes are
    // tracked by observing the window's firstResponder instead.
    private var firstResponderObservation: NSKeyValueObservation?

    init(app: MemtermAppDelegate) {
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
        window.center()
        if let bg = app.config.themeBackground { window.backgroundColor = bg }
        super.init(window: window)
        window.delegate = self
        firstResponderObservation = window.observe(\.firstResponder) { [weak self] window, _ in
            if let pane = window.firstResponder as? PaneView {
                self?.paneFocused(pane)
            }
        }

        let content = NSView(frame: rect)
        window.contentView = content
        let pane = makePane(frame: content.bounds, cwd: nil)
        content.addSubview(pane)
        window.makeFirstResponder(pane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Panes

    private func makePane(frame: NSRect, cwd: String?) -> PaneView {
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

        let shell = config.shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent
        pane.startProcess(executable: shell, execName: "-\(shellName)", currentDirectory: cwd)
        return pane
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
