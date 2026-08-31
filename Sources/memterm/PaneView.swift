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
