import AppKit
import MemtermCore

// Founder UX stage (2026-08-31): "i would almost expect to be able to see the
// workspaces and then click on the name to change vs right clicking".
//
// The workspace bar: a full-width 26 pt strip pinned to the top of each
// tab's content view, directly under the native tab bar. (The
// NSTitlebarAccessoryViewController .bottom placement was tried first and
// measured wrong: with native tabs, EVERY tabbed window's bottom accessory
// stacks into the shared titlebar at once — two tabs rendered two bars,
// 72 pt of chrome — and AppKit forced the height to 36. A content-view bar
// is one-per-tab with exactly the selected tab's visible, which is the
// stage's named fallback.) All workspaces render as chips (color dot +
// name): the active one visually distinct, parked ones dimmed with
// "(parked)", plus a "+" to create one.
//
//   click a chip           = switch to it (reopens if parked)
//   click the ACTIVE chip  = inline rename (label swaps for a text field —
//   / double-click a chip    Enter/focus-loss commits, Esc cancels; no dialog)
//   right-click a chip     = that workspace's menu (Rename, Color, Park/
//                            Reopen, Delete…)
//
// The bar is additive: the old titlebar chip, ⌃⌘n keys, and the Shell menu
// all keep working. Always visible; `workspace_bar = false` hides it.

final class WorkspaceBarView: NSVisualEffectView {
    static let height: CGFloat = 26

    private unowned let app: MemtermAppDelegate
    private let stack = NSStackView()
    private let addButton = NSButton()
    private let separator = NSView()
    private var chipsById: [String: WorkspaceChipView] = [:]

    init(app: MemtermAppDelegate) {
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        material = .headerView
        blendingMode = .withinWindow
        state = .followsWindowActiveState

        // Hairline under the bar so it reads as chrome, not terminal content.
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        separator.autoresizingMask = [.width, .maxYMargin]
        addSubview(separator)

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addButton.title = ""
        addButton.image = NSImage(systemSymbolName: "plus",
                                  accessibilityDescription: "New Workspace")
        addButton.isBordered = false
        addButton.setButtonType(.momentaryChange)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.toolTip = "New Workspace"
        addButton.target = app
        addButton.action = #selector(MemtermAppDelegate.newWorkspaceAction(_:))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    /// FR-58 spirit: right-click on empty bar space still reaches "create".
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Workspaces")
        let item = NSMenuItem(title: "New Workspace…",
                              action: #selector(MemtermAppDelegate.newWorkspaceAction(_:)),
                              keyEquivalent: "")
        item.target = app
        menu.addItem(item)
        return menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Rebuilds the chip row. Chip views are reused by workspace id so an
    /// in-progress inline rename survives unrelated refreshes.
    func update(workspaces: [WorkspaceRow], activeId: String) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var kept: [String: WorkspaceChipView] = [:]
        for workspace in workspaces {
            let chip = chipsById[workspace.id] ?? WorkspaceChipView(app: app,
                                                                    workspaceId: workspace.id)
            chip.configure(name: workspace.name,
                           color: MemtermAppDelegate.nsColor(hex: workspace.color),
                           isActive: workspace.id == activeId,
                           isParked: workspace.isParked)
            kept[workspace.id] = chip
            stack.addArrangedSubview(chip)
        }
        chipsById = kept
        stack.addArrangedSubview(addButton)
    }

    func beginRename(workspaceId: String) {
        chipsById[workspaceId]?.beginRename()
    }

    /// MEMTERM_UI_PROBE support: the rendered chip labels, in order.
    func chipTitlesForProbe() -> [String] {
        stack.arrangedSubviews.compactMap { ($0 as? WorkspaceChipView)?.probeTitle }
    }
}

/// One workspace chip: color dot + name, rounded background when active,
/// dimmed with a "(parked)" suffix when parked. Owns the inline-rename editor.
final class WorkspaceChipView: NSView, NSTextFieldDelegate {
    let workspaceId: String
    private unowned let app: MemtermAppDelegate
    private let label = NSTextField(labelWithString: "")
    private var editor: NSTextField?
    private var renameCancelled = false
    private(set) var isActive = false
    private var isParked = false
    private var name = ""

    init(app: MemtermAppDelegate, workspaceId: String) {
        self.app = app
        self.workspaceId = workspaceId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            heightAnchor.constraint(equalToConstant: 19),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var probeTitle: String {
        "\(name)\(isActive ? "*" : "")\(isParked ? "(parked)" : "")"
    }

    func configure(name: String, color: NSColor, isActive: Bool, isParked: Bool) {
        self.name = name
        self.isActive = isActive
        self.isParked = isParked
        let dimmed = isParked && !isActive
        let title = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: dimmed ? color.withAlphaComponent(0.45) : color,
                         .font: NSFont.systemFont(ofSize: 9)])
        title.append(NSAttributedString(
            string: name,
            attributes: [.foregroundColor: isActive ? NSColor.labelColor
                            : dimmed ? NSColor.tertiaryLabelColor
                            : NSColor.secondaryLabelColor,
                         .font: NSFont.systemFont(ofSize: 11,
                                                  weight: isActive ? .semibold : .medium)]))
        if isParked {
            title.append(NSAttributedString(
                string: "  (parked)",
                attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                             .font: NSFont.systemFont(ofSize: 9)]))
        }
        label.attributedStringValue = title
        layer?.backgroundColor = isActive
            ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        toolTip = isParked ? "\(name) — parked. Click to reopen."
            : isActive ? "Click to rename" : "Switch to \(name)"
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = isActive
            ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    // MARK: - Mouse

    /// The whole chip is one click target: the label must never swallow
    /// clicks or right-clicks (an NSTextField would otherwise receive them
    /// and drop the context-menu path). While the inline editor is up, its
    /// events pass through normally.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if editor != nil { return hit }
        return hit == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard editor == nil else { super.mouseDown(with: event); return }
        if event.clickCount >= 2 || isActive {
            // Active chip's name click, or double-click on any chip: rename.
            // (A double-click on an inactive chip switches on click 1, so
            // click 2 arrives with the chip already active — same path.)
            beginRename()
            return
        }
        // Deferred: switching orders out this chip's own window (the outgoing
        // workspace's, FR-59 hide/show) — never hide the window from inside
        // its own mouseDown.
        let id = workspaceId
        DispatchQueue.main.async { [weak app = self.app] in
            app?.switchToWorkspace(id)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        app.makeWorkspaceChipMenu(for: workspaceId)
    }

    // MARK: - Inline rename (no dialog)

    func beginRename() {
        guard editor == nil else { return }
        let field = NSTextField(string: name)
        field.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        renameCancelled = false
        label.isHidden = true
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
        ])
        editor = field
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Esc cancels; Enter commits by resigning focus (controlTextDidEndEditing).
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = editor else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        editor = nil
        label.isHidden = false
        if !renameCancelled, !newName.isEmpty, newName != name {
            app.memory?.store.renameWorkspace(workspaceId, name: newName)
            app.rebuildWorkspaceMenu()
        }
        renameCancelled = false
        // Keyboard input must return to the terminal: Enter/Esc end editing
        // via makeFirstResponder(nil), which parks focus on the window itself
        // and keystrokes would go nowhere. Hand focus back to the pane —
        // unless something else already claimed it (a focus-loss commit from
        // clicking another responder: that click wins).
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window,
                  window.firstResponder === window,
                  let controller = window.delegate as? TerminalWindowController,
                  let pane = controller.currentPane() else { return }
            window.makeFirstResponder(pane)
        }
    }
}
