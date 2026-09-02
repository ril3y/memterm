import AppKit
import MemtermExtensionKit

// The Timeline panel (⌘⇧T): the flagship memory surface — every closed
// session as a card, grouped by day with reboot seams, attributed to its
// workspace by color and name. Settings-window quality minimum: system
// fonts, standard spacing, native controls, real empty states. The APP owns
// the window (lifecycle, frame memory, theme) — this is only its content.
//
// Layout: search field on top (FTS over archived command history), the
// timeline list in the middle, and a card action bar at the bottom whose
// primary action follows the selection (Reopen Here for a session card,
// Open Workspace for a parked-workspace card).

public final class TimelinePanelController: NSViewController {
    private let host: MemtermHost

    /// How many cards one panel load asks for — a screenful times plenty;
    /// search always queries the full index core-side.
    static let queryLimit = 200

    private var allCards: [SessionCard] = []
    private var parked: [WorkspaceCard] = []
    private(set) var rows: [TimelineModel.Row] = []

    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let reopenButton = NSButton(title: "Reopen Here", target: nil, action: nil)
    private let resumeButton = NSButton(title: "Resume", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Forget…", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal Files", target: nil, action: nil)
    private let emptyBox = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyBody = NSTextField(wrappingLabelWithString: "")

    private static let relativeAge: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    public init(host: MemtermHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 620))

        searchField.placeholderString = "Search archived commands"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        (searchField.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false

        let column = NSTableColumn(identifier: .init("card"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(reopenClicked(_:))
        table.allowsEmptySelection = true

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.autohidesScrollers = true

        reopenButton.target = self
        reopenButton.action = #selector(reopenClicked(_:))
        reopenButton.keyEquivalent = "\r"
        resumeButton.target = self
        resumeButton.action = #selector(resumeClicked(_:))
        forgetButton.target = self
        forgetButton.action = #selector(forgetClicked(_:))
        forgetButton.hasDestructiveAction = true
        revealButton.target = self
        revealButton.action = #selector(revealClicked(_:))
        let buttonRow = NSStackView(views: [forgetButton, revealButton, NSView(),
                                            resumeButton, reopenButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill
        buttonRow.spacing = 8

        emptyTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        emptyBody.font = NSFont.systemFont(ofSize: 11)
        emptyBody.textColor = .tertiaryLabelColor
        emptyBody.alignment = .center
        emptyBox.orientation = .vertical
        emptyBox.alignment = .centerX
        emptyBox.spacing = 6
        emptyBox.addArrangedSubview(emptyTitle)
        emptyBox.addArrangedSubview(emptyBody)
        emptyBox.isHidden = true

        let stack = NSStackView(views: [searchField, scroll, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        emptyBox.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyBox)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            searchField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            buttonRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -14),
            emptyBox.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyBox.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyBox.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -48),
            emptyBody.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view = root
        reload()
    }

    // MARK: - Data

    public func reload() {
        guard isViewLoaded else { return }
        allCards = host.archive.query(ArchiveQuery(limit: Self.queryLimit))
        parked = host.workspace.parkedWorkspaces()
        applyFilter()
    }

    private func applyFilter() {
        let selected = selectedSessionCard()?.id
        let needle = searchField.stringValue
            .trimmingCharacters(in: .whitespaces)
        if needle.isEmpty {
            rows = TimelineModel.rows(cards: allCards, parked: parked)
        } else {
            // FTS over archived command history, core-side; parked cards
            // step back while searching (the query is about sessions).
            rows = TimelineModel.rows(cards: host.archive.search(needle), parked: [])
        }
        table.reloadData()
        let isEmpty = rows.isEmpty
        emptyBox.isHidden = !isEmpty
        if isEmpty {
            if needle.isEmpty {
                emptyTitle.stringValue = "Your timeline is empty"
                emptyBody.stringValue = """
                    Close a tab and its session is filed here — scrollback \
                    frozen, commands searchable, ready to reopen. Quitting \
                    keeps tabs live; only closing archives. Explicit Forget \
                    deletes for real.
                    """
            } else {
                emptyTitle.stringValue = "No matches"
                emptyBody.stringValue =
                    "No archived commands match “\(needle)”."
            }
        }
        if let selected, let row = rowOfSession(id: selected) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateActionState()
    }

    private func rowOfSession(id: SessionID) -> Int? {
        rows.firstIndex { if case .session(let card) = $0 { return card.id == id }
                          return false }
    }

    func selectedSessionCard() -> SessionCard? {
        guard table.selectedRow >= 0, table.selectedRow < rows.count,
              case .session(let card) = rows[table.selectedRow] else { return nil }
        return card
    }

    func selectedWorkspaceCard() -> WorkspaceCard? {
        guard table.selectedRow >= 0, table.selectedRow < rows.count,
              case .workspace(let card) = rows[table.selectedRow] else { return nil }
        return card
    }

    private func updateActionState() {
        let session = selectedSessionCard()
        let workspace = selectedWorkspaceCard()
        if workspace != nil {
            reopenButton.title = "Open Workspace"
            reopenButton.isEnabled = true
        } else {
            reopenButton.title = "Reopen Here"
            reopenButton.isEnabled = session != nil
        }
        resumeButton.isHidden = session?.claudeSessionId == nil
        resumeButton.isEnabled = session?.claudeSessionId != nil
        forgetButton.isEnabled = session != nil
        revealButton.isEnabled = session != nil
    }

    // MARK: - Actions

    @objc private func searchChanged(_ sender: Any?) {
        applyFilter()
    }

    /// Reopen Here: a fresh tab in the archived cwd, the frozen scrollback
    /// fed as a ghost with its divider (feed()-only, by kit construction).
    @discardableResult
    func reopenSession(_ card: SessionCard) -> Bool {
        let cwd = card.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let tab = host.workspace.openTab(cwd, nil) else { return false }
        return host.workspace.reopenGhost(card.id, tab) != nil
    }

    /// Resume: the ghost-bearing reopen PLUS the standard consent-gated
    /// stageResume flow (⌘R + Enter; core owns claims/denylist/composition).
    @discardableResult
    func resumeSession(_ card: SessionCard) -> Bool {
        guard let claudeId = card.claudeSessionId else { return false }
        let cwd = card.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let tab = host.workspace.openTab(cwd, nil) else { return false }
        _ = host.workspace.reopenGhost(card.id, tab)
        return host.workspace.stageResume(claudeId, tab)
    }

    @objc private func reopenClicked(_ sender: Any?) {
        if let workspace = selectedWorkspaceCard() {
            if !host.workspace.openWorkspace(workspace.id) { NSSound.beep() }
            return
        }
        guard let card = selectedSessionCard() else { return }
        if !reopenSession(card) { NSSound.beep() }
    }

    @objc private func resumeClicked(_ sender: Any?) {
        guard let card = selectedSessionCard() else { return }
        if !resumeSession(card) { NSSound.beep() }
    }

    @objc private func forgetClicked(_ sender: Any?) {
        guard let card = selectedSessionCard() else { return }
        // CORE confirms destructively and deletes; .archiveChanged reloads us.
        host.archive.requestForget(card.id)
    }

    @objc private func revealClicked(_ sender: Any?) {
        guard let card = selectedSessionCard() else { return }
        host.archive.revealFiles(card.id)
    }

    // MARK: - Probe seams

    public func probeSetSearch(_ text: String) {
        searchField.stringValue = text
        applyFilter()
    }

    /// Flat render order, one line per row:
    /// "header:<label>" / "reboot" / "workspace:<name>" /
    /// "session:<rowid> ws=<workspaceName>".
    public func probeVisibleRows() -> [String] {
        rows.map { row in
            switch row {
            case .header(let label): return "header:\(label)"
            case .rebootBreak: return "reboot"
            case .workspace(let card): return "workspace:\(card.name)"
            case .session(let card):
                return "session:\(card.id.raw) ws=\(card.workspaceName)"
            }
        }
    }

    public func probeSelectSession(id: String) -> Bool {
        guard let row = rowOfSession(id: SessionID(raw: id)) else { return false }
        table.selectRowIndexes([row], byExtendingSelection: false)
        updateActionState()
        return true
    }

    public func probeSelectWorkspace(name: String) -> Bool {
        guard let row = rows.firstIndex(where: {
            if case .workspace(let card) = $0 { return card.name == name }
            return false
        }) else { return false }
        table.selectRowIndexes([row], byExtendingSelection: false)
        updateActionState()
        return true
    }

    public func probeReopenSelected() -> Bool {
        guard let card = selectedSessionCard() else { return false }
        return reopenSession(card)
    }

    public func probeResumeSelected() -> Bool {
        guard let card = selectedSessionCard() else { return false }
        return resumeSession(card)
    }

    public func probeForgetSelected() -> Bool {
        guard let card = selectedSessionCard() else { return false }
        host.archive.requestForget(card.id)
        return true
    }

    public func probeOpenSelectedWorkspace() -> Bool {
        guard let card = selectedWorkspaceCard() else { return false }
        return host.workspace.openWorkspace(card.id)
    }

    public func probeEmptyState() -> (visible: Bool, title: String, body: String) {
        (!emptyBox.isHidden, emptyTitle.stringValue, emptyBody.stringValue)
    }

    public func probeActionState() -> (reopenTitle: String, reopenEnabled: Bool,
                                       resumeHidden: Bool, forgetEnabled: Bool,
                                       revealEnabled: Bool) {
        (reopenButton.title, reopenButton.isEnabled, resumeButton.isHidden,
         forgetButton.isEnabled, revealButton.isEnabled)
    }
}

// MARK: - Table plumbing + card rendering

extension TimelinePanelController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .session, .workspace: return true
        case .header, .rebootBreak: return false
        }
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 26
        case .rebootBreak: return 18
        case .workspace: return 40
        case .session: return 58
        }
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionState()
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                          row: Int) -> NSView? {
        switch rows[row] {
        case .header(let label): return headerRow(label)
        case .rebootBreak: return rebootRow()
        case .workspace(let card): return workspaceRow(card)
        case .session(let card): return sessionRow(card)
        }
    }

    // -- Row builders (plain views; the table recycles nothing here — the
    // list is small by construction: queryLimit cards + headers) --

    private func headerRow(_ label: String) -> NSView {
        let title = NSTextField(labelWithString: label.uppercased())
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        let row = NSStackView(views: [title])
        row.orientation = .horizontal
        row.alignment = .bottom
        row.edgeInsets = NSEdgeInsets(top: 8, left: 2, bottom: 2, right: 2)
        return row
    }

    /// "— reboot —": a quiet seam, hairlines both sides.
    private func rebootRow() -> NSView {
        func line() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            return box
        }
        let label = NSTextField(labelWithString: "reboot")
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .tertiaryLabelColor
        let left = line(), right = line()
        let row = NSStackView(views: [left, label, right])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        return row
    }

    private func workspaceRow(_ card: WorkspaceCard) -> NSView {
        let dot = colorDot(Self.color(hex: card.colorHex), diameter: 10)
        let name = NSTextField(labelWithString: card.name.isEmpty ? "Workspace" : card.name)
        name.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: "Parked — reopens with its tabs")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let text = NSStackView(views: [name, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return row
    }

    private func sessionRow(_ card: SessionCard) -> NSView {
        // Adapter icon in a soft circle — the card's kind at a glance.
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: Self.symbolName(for: card.kind),
                             accessibilityDescription: card.kind.rawValue)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.wantsLayer = true
        icon.layer?.backgroundColor = NSColor.quaternaryLabelColor
            .withAlphaComponent(0.16).cgColor
        icon.layer?.cornerRadius = 13
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
        ])

        let title = NSTextField(labelWithString: card.title)
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chip = workspaceChip(card)

        let age = NSTextField(labelWithString: card.closedAt.map {
            Self.relativeAge.localizedString(for: $0, relativeTo: Date())
        } ?? "")
        age.font = NSFont.systemFont(ofSize: 11)
        age.textColor = .tertiaryLabelColor
        age.setContentHuggingPriority(.required, for: .horizontal)
        age.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [title, chip, NSView(), age])
        titleRow.orientation = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = 6

        let preview = NSTextField(labelWithString: card.preview)
        preview.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail

        var meta: [String] = []
        if let cwd = card.cwd, !cwd.isEmpty {
            meta.append((cwd as NSString).abbreviatingWithTildeInPath)
        }
        if let duration = TimelineModel.durationLabel(openedAt: card.openedAt,
                                                      closedAt: card.closedAt) {
            meta.append(duration)
        }
        if let reason = TimelineModel.closeReasonLabel(card.closeReason) {
            meta.append(reason)
        }
        let metaLabel = NSTextField(labelWithString: meta.joined(separator: "  ·  "))
        metaLabel.font = NSFont.systemFont(ofSize: 10.5)
        metaLabel.textColor = .tertiaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingMiddle

        let text = NSStackView(views: [titleRow, preview, metaLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        titleRow.leadingAnchor.constraint(equalTo: text.leadingAnchor).isActive = true
        titleRow.trailingAnchor.constraint(equalTo: text.trailingAnchor).isActive = true

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        return row
    }

    /// The workspace attribution chip: tinted capsule, workspace color.
    private func workspaceChip(_ card: SessionCard) -> NSView {
        let color = Self.color(hex: card.workspaceColorHex)
        let name = card.workspaceName.isEmpty ? "workspace" : card.workspaceName
        let label = PaddedChipLabel(labelWithString: name)
        label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.wantsLayer = true
        label.layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        label.layer?.cornerRadius = 7
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        return label
    }

    private func colorDot(_ color: NSColor, diameter: CGFloat) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = diameter / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: diameter),
            dot.heightAnchor.constraint(equalToConstant: diameter),
        ])
        return dot
    }

    static func symbolName(for kind: SessionKind) -> String {
        switch kind {
        case .shell: return "terminal"
        case .claude: return "sparkles"
        case .ssh: return "network"
        case .serial: return "cable.connector"
        }
    }

    /// "#rrggbb" → NSColor; anything else falls back to the neutral label
    /// gray (display only — never trusted for contrast decisions).
    static func color(hex: String) -> NSColor {
        var text = hex.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("#") else { return .secondaryLabelColor }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return .secondaryLabelColor
        }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

/// A label with capsule padding (chips). Draws its background via layer.
final class PaddedChipLabel: NSTextField {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 12
        size.height += 3
        return size
    }
}
