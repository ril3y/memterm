import AppKit
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

    /// Whole buffer (scrollback + visible grid) as plain text, wrapped rows
    /// re-joined, trailing blank grid rows trimmed, capped to maxLines.
    func scrollbackText(maxLines: Int) -> String {
        let terminal = getTerminal()
        var lines: [String] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            let text = line.translateToString(trimRight: true)
            if line.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
            row += 1
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        return lines.joined(separator: "\n")
    }
    override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if copyOnSelect, let text = getSelection(), !text.isEmpty {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
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
