import AppKit
import MemtermCore

// Custom-tab-chrome stage: OUR tab strip. Each tab renders as a rounded body
// FULL-TINTED with its tabColor (the founder's explicit ask, twice — the
// attributed-title pill was the best public-API stand-in under native tabs),
// with a luminance-contrast label, a leading activity mark (spinner → unseen
// dot, driven by the tab's existing TabActivityTracker), a hover ✕ close, a
// trailing "+" (⌘T plumbing), double-click rename, right-click context menu,
// and in-strip drag reorder. Layout math is MemtermCore.TabStripLayout
// (equal widths squeezing to a 72 pt floor, then horizontal scrolling).
// Strip background drags the window; double-click on background zooms.

final class TabStripView: NSVisualEffectView {
    static let height: CGFloat = 30

    private unowned let app: MemtermAppDelegate
    private weak var host: WindowHostController?
    private let scrollView = NSScrollView()
    private let content = TabStripBackgroundView()
    private let plusButton = NSButton()
    private let separator = NSView()
    private var items: [TabItemView] = []
    private var layoutModel = TabStripLayout(available: 0, count: 0)

    /// Set by the host: the top visible chrome row clears the traffic lights.
    var leadingInset: CGFloat = 8 {
        didSet { needsLayout = true }
    }

    // -- Drag-reorder state --
    private var pressedItem: TabItemView?
    private var pressOffsetInItem: CGFloat = 0
    private var dragActive = false

    init(app: MemtermAppDelegate, host: WindowHostController) {
        self.app = app
        self.host = host
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        material = .headerView
        blendingMode = .withinWindow
        state = .followsWindowActiveState

        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        addSubview(separator)

        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = content
        addSubview(scrollView)

        plusButton.title = ""
        plusButton.image = NSImage(systemSymbolName: "plus",
                                   accessibilityDescription: "New Tab")
        plusButton.isBordered = false
        plusButton.setButtonType(.momentaryChange)
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.toolTip = "New Tab (⌘T)"
        plusButton.target = app
        plusButton.action = #selector(MemtermAppDelegate.newWindowForTab(_:))
        addSubview(plusButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        for item in items { item.repaint() }
    }

    /// Empty strip space is chrome: dragging it moves the window.
    override var mouseDownCanMoveWindow: Bool { true }

    // MARK: - Model sync

    /// Full rebuild from host.tabs (item views reused by identity so hover /
    /// drag state survives unrelated refreshes).
    func reload() {
        guard let host else { return }
        var byTab: [ObjectIdentifier: TabItemView] = [:]
        for item in items {
            if let tab = item.tab { byTab[ObjectIdentifier(tab)] = item }
        }
        var next: [TabItemView] = []
        for tab in host.tabs {
            let item = byTab.removeValue(forKey: ObjectIdentifier(tab))
                ?? TabItemView(app: app, strip: self, tab: tab)
            item.configure(selected: tab === host.selectedTab)
            if item.superview !== content { content.addSubview(item) }
            next.append(item)
        }
        for orphan in byTab.values { orphan.removeFromSuperview() }
        items = next
        needsLayout = true
        layoutItems()
    }

    /// Reorders the item array to match host.tabs without rebuilding views
    /// (used mid-drag: the dragged item keeps tracking the mouse).
    func syncOrder() {
        guard let host else { return }
        var byTab: [ObjectIdentifier: TabItemView] = [:]
        for item in items {
            if let tab = item.tab { byTab[ObjectIdentifier(tab)] = item }
        }
        items = host.tabs.compactMap { byTab[ObjectIdentifier($0)] }
        layoutItems(except: dragActive ? pressedItem : nil)
    }

    func refreshItem(for tab: TerminalWindowController) {
        guard let item = items.first(where: { $0.tab === tab }) else { return }
        item.configure(selected: tab === host?.selectedTab)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        let plusSize: CGFloat = 24
        plusButton.frame = NSRect(x: bounds.width - plusSize - 6,
                                  y: (bounds.height - plusSize) / 2 + 0.5,
                                  width: plusSize, height: plusSize)
        scrollView.frame = NSRect(x: leadingInset, y: 1,
                                  width: max(0, plusButton.frame.minX - leadingInset - 4),
                                  height: bounds.height - 1)
        layoutItems()
    }

    private func layoutItems(except floating: TabItemView? = nil) {
        layoutModel = TabStripLayout(available: Double(scrollView.frame.width),
                                     count: items.count)
        let contentWidth = max(CGFloat(layoutModel.contentWidth), scrollView.frame.width)
        content.frame = NSRect(x: 0, y: 0, width: contentWidth,
                               height: scrollView.frame.height)
        for (index, item) in items.enumerated() where item !== floating {
            item.frame = frameForItem(at: index)
        }
    }

    private func frameForItem(at index: Int) -> NSRect {
        NSRect(x: CGFloat(layoutModel.xOrigin(of: index)), y: 3,
               width: CGFloat(layoutModel.tabWidth),
               height: max(0, content.frame.height - 7))
    }

    // MARK: - Interaction (called by TabItemView)

    func itemPressed(_ item: TabItemView, event: NSEvent) {
        pressedItem = item
        dragActive = false
        let inContent = content.convert(event.locationInWindow, from: nil)
        pressOffsetInItem = inContent.x - item.frame.minX
        // Like native tabs, mouse-down selects.
        if let tab = item.tab { host?.select(tab) }
    }

    func itemDragged(_ item: TabItemView, event: NSEvent) {
        guard item === pressedItem, let host, items.count > 1 else { return }
        dragActive = true
        let inContent = content.convert(event.locationInWindow, from: nil)
        let maxX = content.frame.width - item.frame.width
        let newX = min(max(0, inContent.x - pressOffsetInItem), max(0, maxX))
        item.frame.origin.x = newX
        // Autoscroll while dragging near the clipped edges.
        item.autoscroll(with: event)
        guard let fromIndex = items.firstIndex(where: { $0 === item }) else { return }
        let target = layoutModel.dropIndex(forDragCenterX: Double(item.frame.midX))
        if target != fromIndex {
            host.reorderTab(from: fromIndex, to: target)
        }
    }

    func itemMouseUp(_ item: TabItemView, event: NSEvent) {
        guard item === pressedItem else { return }
        pressedItem = nil
        if dragActive {
            dragActive = false
            layoutItems()  // snap the dragged tab into its slot
            host?.reorderCommitted()
        }
    }

    func closeItem(_ item: TabItemView) {
        // FR-56: the hover ✕ is a user gesture; close() infers user intent
        // from the live flags (active workspace, not quitting/switching).
        item.tab?.close()
    }

    func renameItem(_ item: TabItemView) {
        item.tab?.promptRenameTab()
    }

    func contextMenu(for item: TabItemView) -> NSMenu? {
        guard let tab = item.tab else { return nil }
        return app.makeTabContextMenu(for: tab)
    }

    // MARK: - Background gestures

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)  // double-click on empty chrome keeps zoom
            return
        }
        // The strip row sits BELOW the system titlebar region, so background
        // drags need the explicit drag API (the native tab bar got titlebar
        // dragging for free).
        window?.performDrag(with: event)
    }

    // MARK: - Probe support (MEMTERM_UI_PROBE): direct hit-test assertions
    // replace the old synthesized-event monitor BAND leg.

    /// The tabId under a point in the strip's CONTENT coordinates, or nil for
    /// background/gap space.
    func probeTabId(atContentX x: CGFloat) -> String? {
        guard let index = layoutModel.hitTest(x: Double(x)),
              items.indices.contains(index) else { return nil }
        return items[index].tab?.tabId
    }

    func probeItemFrame(of tabId: String) -> NSRect? {
        items.first { $0.tab?.tabId == tabId }?.frame
    }

    /// The rendered text color of a tab's label (tint-contrast probe).
    func probeLabelColor(of tabId: String) -> NSColor? {
        items.first { $0.tab?.tabId == tabId }?.probeLabelColor
    }

    func probeTabIds() -> [String] {
        items.compactMap { $0.tab?.tabId }
    }
}

/// Scrollable strip content: background drags the window.
final class TabStripBackgroundView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isFlipped: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
            return
        }
        window?.performDrag(with: event)
    }
}

/// One tab body in the strip.
final class TabItemView: NSView {
    private unowned let app: MemtermAppDelegate
    private weak var strip: TabStripView?
    private(set) weak var tab: TerminalWindowController?

    private let label = NSTextField(labelWithString: "")
    private let activityView = TabActivityIndicatorView()
    private let closeButton = NSButton()
    private var selected = false
    private var hovered = false

    init(app: MemtermAppDelegate, strip: TabStripView, tab: TerminalWindowController) {
        self.app = app
        self.strip = strip
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        activityView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activityView)

        closeButton.isBordered = false
        closeButton.setButtonType(.momentaryChange)
        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.alphaValue = 0  // revealed on hover
        closeButton.target = self
        closeButton.action = #selector(closeTapped(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            activityView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            activityView.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityView.widthAnchor.constraint(equalToConstant: 16),
            activityView.heightAnchor.constraint(equalToConstant: 16),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: activityView.trailingAnchor, constant: 1),
            label.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -1),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A tab body handles its own clicks — never a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    var probeLabelColor: NSColor? { label.textColor }

    func configure(selected: Bool) {
        self.selected = selected
        guard let tab else { return }
        label.stringValue = tab.displayTitle
        toolTip = tab.displayTitle
        setAccessibilityLabel(tab.displayTitle)
        setAccessibilityValue(selected)
        activityView.apply(state: selected ? .idle : tab.activityStateForProbe())
        repaint()
    }

    /// Full-tab tint (founder's screenshot): the selected tab gets the full-
    /// saturation fill with a luminance-contrast label; unselected tabs are
    /// tinted at reduced alpha; nil color falls back to system materials.
    func repaint() {
        guard let tab else { return }
        let tint = tab.tabColor.map { MemtermAppDelegate.nsColor(hex: $0) }
        if let tint {
            let srgb = tint.usingColorSpace(.sRGB) ?? tint
            let darkText = TabTint.useDarkText(red: Double(srgb.redComponent),
                                               green: Double(srgb.greenComponent),
                                               blue: Double(srgb.blueComponent))
            if selected {
                layer?.backgroundColor = tint.cgColor
                label.textColor = darkText ? .black : .white
            } else {
                layer?.backgroundColor = tint.withAlphaComponent(hovered ? 0.45 : 0.32).cgColor
                label.textColor = .labelColor
            }
        } else if selected {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.16).cgColor
            label.textColor = .labelColor
        } else {
            layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(hovered ? 0.08 : 0.04).cgColor
            label.textColor = .secondaryLabelColor
        }
        label.font = NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .medium)
    }

    func applyActivity(_ state: TabActivityState) {
        activityView.apply(state: selected ? .idle : state)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        repaint()
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        closeButton.animator().alphaValue = 1
        repaint()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        closeButton.animator().alphaValue = 0
        repaint()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            strip?.renameItem(self)
            return
        }
        strip?.itemPressed(self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        strip?.itemDragged(self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        strip?.itemMouseUp(self, event: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.contextMenu(for: self)
    }

    @objc private func closeTapped(_ sender: Any?) {
        strip?.closeItem(self)
    }
}
