import AppKit
import MemtermExtensionKit

// The Claude Sessions browser panel: a clean single-purpose window
// (Settings-window quality — system fonts, standard spacing, native
// controls). Registered via host.ui.registerPanel; the APP owns the window
// (lifecycle, frame memory, theme) — this is only its content.
//
// Layout: search field on top, project-grouped outline in the middle,
// action bar (Reveal in Finder / Resume in New Tab) at the bottom, and a
// centered empty state naming the looked-in path when the scan finds
// nothing.

public final class ClaudeSessionsPanelController: NSViewController {
    private let host: MemtermHost

    // Reference wrappers: NSOutlineView items must be identity objects.
    final class GroupNode {
        let group: ClaudeBrowserModel.ProjectGroup
        let children: [SessionNode]
        init(_ group: ClaudeBrowserModel.ProjectGroup) {
            self.group = group
            children = group.sessions.map { SessionNode($0, slug: group.project.slug) }
        }
    }
    final class SessionNode {
        let info: ClaudeSessionInfo
        let slug: String
        init(_ info: ClaudeSessionInfo, slug: String) {
            self.info = info
            self.slug = slug
        }
    }

    private var allGroups: [ClaudeBrowserModel.ProjectGroup] = []
    private var nodes: [GroupNode] = []

    private let searchField = NSSearchField()
    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let resumeButton = NSButton(title: "Resume in New Tab", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let emptyBox = NSStackView()
    private let emptyTitle = NSTextField(labelWithString: "No Claude sessions found")
    private let emptyPath = NSTextField(labelWithString: "")

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
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 540))

        searchField.placeholderString = "Filter by project or text"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        (searchField.cell as? NSSearchFieldCell)?.sendsWholeSearchString = false

        let column = NSTableColumn(identifier: .init("session"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 38
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 0
        outline.style = .inset
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(resumeClicked(_:))
        outline.allowsEmptySelection = true

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.autohidesScrollers = true

        resumeButton.target = self
        resumeButton.action = #selector(resumeClicked(_:))
        resumeButton.keyEquivalent = "\r"
        revealButton.target = self
        revealButton.action = #selector(revealClicked(_:))
        let buttonRow = NSStackView(views: [revealButton, NSView(), resumeButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill

        emptyTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyPath.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        emptyPath.textColor = .tertiaryLabelColor
        emptyPath.lineBreakMode = .byTruncatingMiddle
        emptyBox.orientation = .vertical
        emptyBox.alignment = .centerX
        emptyBox.spacing = 6
        emptyBox.addArrangedSubview(emptyTitle)
        emptyBox.addArrangedSubview(emptyPath)
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
            emptyBox.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -32),
        ])
        view = root
        reload()
    }

    // MARK: - Data

    public func reload() {
        guard isViewLoaded else { return }
        allGroups = ClaudeBrowserModel.groups(projects: host.claude.projects(),
                                              fetchSessions: host.claude.sessions)
        applyFilter()
    }

    private func applyFilter() {
        let selected = selectedSessionNode()?.info.id
        let filtered = ClaudeBrowserModel.filter(allGroups,
                                                 query: searchField.stringValue)
        nodes = filtered.map(GroupNode.init)
        outline.reloadData()
        for node in nodes { outline.expandItem(node) }
        let isEmpty = nodes.isEmpty
        emptyBox.isHidden = !isEmpty
        emptyPath.stringValue = "Looked in \(host.claude.rootDisplayPath())"
        if let selected,
           let row = rowOfSession(id: selected) {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateButtonState()
    }

    private func rowOfSession(id: ClaudeSessionID) -> Int? {
        for node in nodes {
            for child in node.children where child.info.id == id {
                let row = outline.row(forItem: child)
                if row >= 0 { return row }
            }
        }
        return nil
    }

    private func selectedSessionNode() -> SessionNode? {
        guard outline.selectedRow >= 0 else { return nil }
        return outline.item(atRow: outline.selectedRow) as? SessionNode
    }

    private func updateButtonState() {
        let hasSession = selectedSessionNode() != nil
        resumeButton.isEnabled = hasSession
        revealButton.isEnabled = hasSession
    }

    // MARK: - Actions

    @objc private func searchChanged(_ sender: Any?) {
        applyFilter()
    }

    /// openTab THEN stageResume: the consent-gated ⌘R offer appears in the
    /// new tab; nothing runs without the user's ⌘R + Enter. Command strings
    /// never reach this module.
    @discardableResult
    func resumeSession(_ node: SessionNode) -> Bool {
        let cwd = node.info.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        guard let tab = host.workspace.openTab(cwd, nil) else { return false }
        return host.workspace.stageResume(node.info.id, tab)
    }

    @objc private func resumeClicked(_ sender: Any?) {
        guard let node = selectedSessionNode() else { return }
        if !resumeSession(node) { NSSound.beep() }
    }

    @objc private func revealClicked(_ sender: Any?) {
        guard let node = selectedSessionNode() else { return }
        host.claude.revealSession(node.info.id, node.slug)
    }

    // MARK: - Probe seams

    public func probeSetSearch(_ text: String) {
        searchField.stringValue = text
        applyFilter()
    }

    /// Flat render order: "project:<displayPath>" then "session:<id>" rows.
    public func probeVisibleRows() -> [String] {
        nodes.flatMap { node in
            ["project:\(node.group.displayPath)"]
                + node.children.map { "session:\($0.info.id.raw)" }
        }
    }

    public func probeSelectSession(id: String) -> Bool {
        guard let row = rowOfSession(id: ClaudeSessionID(raw: id)) else { return false }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        updateButtonState()
        return true
    }

    public func probeResumeSelected() -> Bool {
        guard let node = selectedSessionNode() else { return false }
        return resumeSession(node)
    }

    public func probeEmptyState() -> (visible: Bool, path: String) {
        (!emptyBox.isHidden, emptyPath.stringValue)
    }

    public func probeButtonsEnabled() -> (resume: Bool, reveal: Bool) {
        (resumeButton.isEnabled, revealButton.isEnabled)
    }
}

// MARK: - Outline plumbing

extension ClaudeSessionsPanelController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    public func outlineView(_ outlineView: NSOutlineView,
                            numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? GroupNode else { return nodes.count }
        return node.children.count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int,
                            ofItem item: Any?) -> Any {
        guard let node = item as? GroupNode else { return nodes[index] }
        return node.children[index]
    }

    public func outlineView(_ outlineView: NSOutlineView,
                            isItemExpandable item: Any) -> Bool {
        item is GroupNode
    }

    public func outlineView(_ outlineView: NSOutlineView,
                            isGroupItem item: Any) -> Bool {
        item is GroupNode
    }

    public func outlineView(_ outlineView: NSOutlineView,
                            shouldSelectItem item: Any) -> Bool {
        item is SessionNode
    }

    public func outlineView(_ outlineView: NSOutlineView,
                            heightOfRowByItem item: Any) -> CGFloat {
        item is GroupNode ? 26 : 38
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
    }

    public func outlineView(_ outlineView: NSOutlineView,
                            viewFor tableColumn: NSTableColumn?,
                            item: Any) -> NSView? {
        if let node = item as? GroupNode { return groupRow(node) }
        guard let node = item as? SessionNode else { return nil }
        return sessionRow(node)
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func groupRow(_ node: GroupNode) -> NSView {
        let title = NSTextField(labelWithString: abbreviate(node.group.displayPath))
        title.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        let count = node.children.count
        let counter = NSTextField(labelWithString: "\(count) session\(count == 1 ? "" : "s")")
        counter.font = NSFont.systemFont(ofSize: 11)
        counter.textColor = .tertiaryLabelColor
        let row = NSStackView(views: [title, NSView(), counter])
        row.orientation = .horizontal
        row.alignment = .lastBaseline
        return row
    }

    private func sessionRow(_ node: SessionNode) -> NSView {
        let info = node.info
        let title = NSTextField(labelWithString: info.lastPrompt ?? "Session \(info.id.raw.prefix(8))")
        title.font = NSFont.systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1

        var details = "\(info.id.raw.prefix(8)) · \(Self.relativeAge.localizedString(for: info.lastActivity, relativeTo: Date()))"
        if info.isLive {
            details += info.needsAttention ? " · needs input" : " · working"
        }
        if let version = info.claudeVersion { details += " · v\(version)" }
        let subtitle = NSTextField(labelWithString: details)
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let dot = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        switch ClaudeBrowserModel.attentionState(for: info) {
        case .attention: dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        case .active: dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        case .none: dot.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        }
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])

        let row = NSStackView(views: [dot, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }
}
