import AppKit
import MemtermCore
import SwiftTerm

// One terminal pane: a LocalProcessTerminalView plus the Stage-1 UX behaviors
// (copy-on-select, middle-click paste, focus dimming) and per-pane state the
// window controller reads for titles and split inheritance.

final class PaneView: LocalProcessTerminalView {
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
    /// Shell executable this pane spawned; restored panes respawn the same one.
    var shellPath: String?

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
        guard let controller = window?.delegate as? TerminalWindowController else {
            return super.menu(for: event)
        }
        return controller.contextMenu(for: self)
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
