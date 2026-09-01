import AppKit
import MemtermCore

// Founder UX stage (2026-08-31): "i would almost expect to be able to see the
// workspaces and then click on the name to change vs right clicking" — and
// then: "workspaces should be on top then tabs below it".
//
// The workspace bar: a 26 pt strip, row 1 of the custom chrome
// (WindowHostController hosts it as a PLAIN subview above our TabStripView —
// the custom-tab-chrome stage; the titlebar-accessory homes of earlier
// stages, and their height/stacking caveats, are gone). Because the bar is
// plain chrome now, the host passes the traffic-light clearance as
// leadingInset (AppKit no longer insets it for free) and window.title stays
// synced on the host. All workspaces render as chips (color dot + name):
// the active one visually distinct, parked ones dimmed with "(parked)",
// plus a "+" to create one.
//
//   click a chip           = switch to it (reopens if parked)
//   click the ACTIVE chip  = inline rename (label swaps for a text field —
//   / double-click a chip    Enter/focus-loss commits, Esc cancels; no dialog)
//   right-click a chip     = that workspace's menu (Rename, Color, Park/
//                            Reopen, Delete…)
//
// The bar is additive: the gear's workspace popup, ⌃⌘n keys, and the Shell
// menu all keep working. Always visible; `workspace_bar = false` hides it.

final class WorkspaceBarView: NSVisualEffectView {
    static let height: CGFloat = 26

    private unowned let app: MemtermAppDelegate
    private let stack = NSStackView()
    private let addButton = NSButton()
    private let separator = NSView()
    /// Founder request: the bar names itself so the chips are self-explanatory.
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Workspaces:")
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }()
    private var chipsById: [String: WorkspaceChipView] = [:]
    private let leadingInset: CGFloat

    /// `leadingInset`: where the chip row starts. Under the custom chrome the
    /// bar is the TOP chrome row of a plain window, so the host passes the
    /// traffic-light clearance (the titlebar-accessory era got that inset
    /// from AppKit for free).
    init(app: MemtermAppDelegate, leadingInset: CGFloat = 10) {
        self.app = app
        self.leadingInset = leadingInset
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

        // Trailing clearance 44: the bar row shares its trailing edge with
        // the gear button (the old .right accessory, now a chrome subview) —
        // chips must never crowd under it. Leading comes from the host
        // (traffic-light clearance when this is the top chrome row).
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingInset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -44),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    /// Chrome-row placement: empty bar space acts as titlebar — dragging
    /// the window by it must keep working (chips opt out; they handle clicks).
    override var mouseDownCanMoveWindow: Bool { true }

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
    /// in-progress inline rename survives unrelated refreshes. `activity`:
    /// per-workspace output marks (founder UX: a hidden workspace's chip
    /// pulses while output flows, keeps an unseen ring after).
    func update(workspaces: [WorkspaceRow], activeId: String,
                activity: [String: TabActivityState] = [:]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        stack.addArrangedSubview(titleLabel)
        var kept: [String: WorkspaceChipView] = [:]
        for workspace in workspaces {
            let chip = chipsById[workspace.id] ?? WorkspaceChipView(app: app,
                                                                    workspaceId: workspace.id)
            chip.configure(name: workspace.name,
                           color: MemtermAppDelegate.nsColor(hex: workspace.color),
                           isActive: workspace.id == activeId,
                           isParked: workspace.isParked,
                           activity: activity[workspace.id] ?? .idle)
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

    /// MEMTERM_UI_PROBE support: the activity mark a chip is rendering.
    func chipActivityForProbe(workspaceId: String) -> TabActivityState? {
        chipsById[workspaceId]?.activityState
    }

    /// TESTING.md §2.3 (bug 2 regression): each chip's frame in bar
    /// coordinates, for rendered-bitmap contrast sampling.
    func probeChipFrames() -> [(id: String, frame: NSRect)] {
        chipsById.compactMap { id, chip in
            guard chip.superview != nil, chip.frame.width >= 1 else { return nil }
            return (id, chip.convert(chip.bounds, to: self))
        }
    }

    /// TESTING.md §2.3 (bug 2, text half): each chip's LABEL frame in bar
    /// coordinates. The whole-chip sample can be carried by the color dot /
    /// active background while the text itself is invisible — meta-gate
    /// mutation (chip text alpha 0.05) proved it — so the gate samples the
    /// text region separately.
    func probeChipLabelFrames() -> [(id: String, frame: NSRect)] {
        chipsById.compactMap { id, chip in
            guard chip.superview != nil, chip.frame.width >= 1,
                  chip.probeLabelFrame.width >= 1 else { return nil }
            return (id, chip.convert(chip.probeLabelFrame, to: self))
        }
    }
}

/// One workspace chip: color dot + name, rounded background when active,
/// dimmed with a "(parked)" suffix when parked. Owns the inline-rename editor.
/// The dot is a real layer-backed view (not a glyph) so it can carry the
/// activity marks: a pulse while a hidden workspace's output flows, a ring
/// while output sits unseen (WorkspaceActivityCenter drives the states).
final class WorkspaceChipView: NSView, NSTextFieldDelegate {
    let workspaceId: String
    private unowned let app: MemtermAppDelegate
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let ring = NSView()
    /// Founder 2026-08-31: quick close on hover — ✕ parks a live workspace
    /// (memory kept, reversible); on an already-parked chip it forgets, with
    /// one confirmation since that deletes memory. Space is always reserved so
    /// chips don't jump on hover; the glyph fades in.
    private let closeButton = NSButton()
    private var editor: NSTextField?
    private var renameCancelled = false
    private(set) var isActive = false
    private var isParked = false
    private var name = ""
    private var dotColor = NSColor.systemGray
    private(set) var activityState: TabActivityState = .idle

    private static let pulseKey = "memterm.chip.pulse"

    init(app: MemtermAppDelegate, workspaceId: String) {
        self.app = app
        self.workspaceId = workspaceId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 6
        ring.layer?.borderWidth = 1.5
        ring.isHidden = true
        addSubview(ring)
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        addSubview(dot)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close Workspace")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.alphaValue = 0  // revealed on hover
        closeButton.target = self
        closeButton.action = #selector(closeTapped(_:))
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            ring.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 12),
            ring.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 13),
            closeButton.heightAnchor.constraint(equalToConstant: 13),
            heightAnchor.constraint(equalToConstant: 19),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.animator().alphaValue = 1
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.animator().alphaValue = 0
    }

    @objc private func closeTapped(_ sender: Any?) {
        let id = workspaceId
        if isParked {
            // Forget deletes memory — one confirmation, then gone.
            let alert = NSAlert()
            alert.messageText = "Forget “\(name)”?"
            alert.informativeText = "Deletes this workspace's memory — layouts, scrollback, session records."
            alert.addButton(withTitle: "Forget")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            DispatchQueue.main.async { [weak app = self.app] in
                app?.forgetWorkspace(id)
            }
        } else {
            // Park = close but keep memory (FR-51); reversible from the chip.
            // Deferred: parking hides/closes this chip's own window path.
            DispatchQueue.main.async { [weak app = self.app] in
                app?.parkWorkspace(id)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var probeTitle: String {
        "\(name)\(isActive ? "*" : "")\(isParked ? "(parked)" : "")"
    }

    /// The name label's frame (chip coordinates) — the text region the bug-2
    /// gate samples independently of the dot/background decorations.
    var probeLabelFrame: NSRect { label.frame }

    func configure(name: String, color: NSColor, isActive: Bool, isParked: Bool,
                   activity: TabActivityState = .idle) {
        self.name = name
        self.isActive = isActive
        self.isParked = isParked
        let dimmed = isParked && !isActive
        dotColor = dimmed ? color.withAlphaComponent(0.45) : color
        let title = NSMutableAttributedString(
            string: name,
            attributes: [.foregroundColor: isActive ? NSColor.labelColor
                            : dimmed ? NSColor.tertiaryLabelColor
                            : NSColor.secondaryLabelColor,
                         .font: NSFont.systemFont(ofSize: 11,
                                                  weight: isActive ? .semibold : .medium)])
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
        // The active workspace's chip never indicates (the user is looking at
        // it) — belt and braces on top of the center's own guard.
        applyActivity(isActive ? .idle : activity)
        toolTip = isParked ? "\(name) — parked. Click to reopen."
            : isActive ? "Click to rename" : "Switch to \(name)"
        closeButton.toolTip = isParked ? "Forget \(name)…" : "Park \(name) (keeps its memory)"
    }

    /// Dot pulse while output flows in this (hidden) workspace; a persistent
    /// ring once it stops, cleared by switching to the workspace.
    private func applyActivity(_ state: TabActivityState) {
        activityState = state
        dot.layer?.backgroundColor = dotColor.cgColor
        ring.layer?.borderColor = dotColor.cgColor
        ring.isHidden = state != .unseen
        if state == .active {
            if dot.layer?.animation(forKey: Self.pulseKey) == nil {
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = 1.0
                pulse.toValue = 0.25
                pulse.duration = 0.45
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                dot.layer?.add(pulse, forKey: Self.pulseKey)
            }
        } else {
            dot.layer?.removeAnimation(forKey: Self.pulseKey)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = isActive
            ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
        dot.layer?.backgroundColor = dotColor.cgColor
        ring.layer?.borderColor = dotColor.cgColor
    }

    // MARK: - Mouse

    /// In the chrome row, a chip click must be a click (switch / rename),
    /// never the start of a window drag — the bar's background keeps the
    /// drag affordance instead.
    override var mouseDownCanMoveWindow: Bool { false }

    /// The whole chip is one click target: the label must never swallow
    /// clicks or right-clicks (an NSTextField would otherwise receive them
    /// and drop the context-menu path). While the inline editor is up, its
    /// events pass through normally.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if editor != nil { return hit }
        // The hover ✕ keeps its own click; everything else is the chip.
        if let hit, hit === closeButton || hit.isDescendant(of: closeButton) { return hit }
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

    /// Esc cancels; Enter commits. Both end editing by handing the first
    /// responder STRAIGHT to the pane: makeFirstResponder(pane) resigns the
    /// field editor (running the commit/cancel logic in
    /// controlTextDidEndEditing) and lands the keyboard in the terminal in
    /// one atomic step. The previous two-step dance — makeFirstResponder(nil)
    /// parking focus on the window, an async block re-targeting the pane —
    /// raced AppKit's field-editor teardown and intermittently stranded the
    /// keyboard on the window (probe-reproduced); the async handoff in
    /// controlTextDidEndEditing remains only as the fallback for OTHER
    /// end-editing paths.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            renameCancelled = true
            endEditingReturningFocusToPane()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            endEditingReturningFocusToPane()
            return true
        }
        return false
    }

    private func endEditingReturningFocusToPane() {
        guard let window else { return }
        if let host = window.delegate as? WindowHostController,
           let pane = host.selectedTab?.currentPane() {
            window.makeFirstResponder(pane)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    /// MEMTERM_UI_PROBE diagnostics: the rename-commit focus handoff is the
    /// probe's flakiest contract — log every step of end-editing so a failed
    /// run says WHERE the handoff died (never fired / guard bailed / AppKit
    /// refused the responder change).
    private static let probeLogging =
        ProcessInfo.processInfo.environment["MEMTERM_UI_PROBE"] == "1"

    private func probeLog(_ message: @autoclosure () -> String) {
        if Self.probeLogging { print("UIPROBE-RENAME-TRACE \(message())") }
    }

    /// Single-line responder name for the trace (NSTextView's description is
    /// multi-line and would shred the probe log).
    private static func describeResponder(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return "\(type(of: responder))(\(Unmanaged.passUnretained(responder).toOpaque()))"
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        probeLog("endEditing fired editor=\(editor != nil) fr=\(Self.describeResponder(window?.firstResponder))")
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
        // Keyboard input must return to the terminal: a focus-loss commit
        // (makeFirstResponder(nil)) parks focus on the window itself — and,
        // probe-reproduced, AppKit can also leave the DYING field's orphaned
        // field editor as first responder past this notification. Hand focus
        // back to the pane in both cases — unless something else already
        // claimed it (a focus-loss commit from clicking another responder:
        // that click wins; its field editor has a different delegate).
        let dyingField = field
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let window = self.window,
                  let host = window.delegate as? WindowHostController,
                  let pane = host.selectedTab?.currentPane() else {
                self.probeLog("handoff bailed window=\(self.window != nil) host=\((self.window?.delegate as? WindowHostController) != nil)")
                return
            }
            let fr = window.firstResponder
            let orphanEditor = (fr as? NSTextView)?.delegate as? NSTextField === dyingField
            guard fr === window || fr == nil || orphanEditor else {
                self.probeLog("handoff skipped: fr already claimed by \(Self.describeResponder(fr))")
                return
            }
            let accepted = window.makeFirstResponder(pane)
            self.probeLog("handoff makeFirstResponder(pane)=\(accepted) fr_now=\(Self.describeResponder(window.firstResponder))")
        }
    }
}
