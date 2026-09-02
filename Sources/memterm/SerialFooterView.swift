import AppKit
import MemtermCore

// Serial footer bar (founder ask): a slim status strip pinned to the bottom
// of every SERIAL pane — shell panes unchanged. Left to right: state dot,
// port label, settings summary with the BAUD as a clickable control (menu of
// standard rates + Custom…, applied LIVE to the open fd), TX/RX lifetime
// counters, DTR/RTS chips (filled = asserted, click to toggle), and a HEX
// badge while the hex lens is on. All logic (counters, formatting, throttle,
// state mapping) lives in MemtermCore.SerialFooterModel; this face paints
// what the model says and forwards clicks to the pane.
//
// Visual system: the find-bar family — NSVisualEffectView, small mono font
// for the counters, 22 pt tall. The footer never steals first responder:
// every control refuses it, so the keyboard stays with the terminal.

/// A small pill button: filled = asserted (DTR/RTS chips).
final class SerialChipButton: NSButton {

    private(set) var isFilled = false

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        refusesFirstResponder = true
        setContentHuggingPriority(.required, for: .horizontal)
        applyFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 10
        size.height = 15
        return size
    }

    func setFilled(_ filled: Bool) {
        guard filled != isFilled else { return }
        isFilled = filled
        applyFill()
    }

    private func applyFill() {
        let text: NSColor = isFilled ? .white : .secondaryLabelColor
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: font ?? .monospacedSystemFont(ofSize: 9, weight: .semibold),
                         .foregroundColor: text])
        layer?.backgroundColor = isFilled
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        layer?.borderColor = isFilled
            ? NSColor.controlAccentColor.cgColor
            : NSColor.tertiaryLabelColor.cgColor
    }

    override func updateLayer() {
        super.updateLayer()
        applyFill()  // re-resolve dynamic colors on appearance changes
    }
}

final class SerialFooterView: NSVisualEffectView {

    static let barHeight: CGFloat = 22

    // Click handlers — wired by SerialPaneView; the footer owns no state.
    var onSelectBaud: ((Int) -> Void)?
    var onCustomBaud: (() -> Void)?
    var onToggleDTR: (() -> Void)?
    var onToggleRTS: (() -> Void)?
    /// The state dot's click: Connect/Disconnect toggle (founder disconnect/
    /// connect stage) — the pane decides which, from its link state.
    var onToggleConnection: (() -> Void)?

    // Current painted state, readable by the probe (rendered-truth twin is
    // the bitmap assertion; these are the strip hit-test-style accessors).
    private(set) var currentLinkState: SerialFooterModel.LinkState = .disconnected
    private(set) var currentBaud = 0

    /// The state dot IS the Connect/Disconnect toggle button (tooltip states
    /// the action). Internal so the probe can drive the REAL button action.
    let dotButton = NSButton()
    private let portLabel = NSTextField(labelWithString: "")
    private let baudButton = NSButton()
    private let frameLabel = NSTextField(labelWithString: "")
    private let hexBadge = NSTextField(labelWithString: "HEX")
    let dtrChip = SerialChipButton(title: "DTR")
    let rtsChip = SerialChipButton(title: "RTS")
    private let txLabel = NSTextField(labelWithString: "TX 0 B")
    private let rxLabel = NSTextField(labelWithString: "RX 0 B")

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active

        dotButton.isBordered = false
        dotButton.setButtonType(.momentaryChange)
        dotButton.refusesFirstResponder = true
        dotButton.target = self
        dotButton.action = #selector(dotClicked)
        dotButton.setContentHuggingPriority(.required, for: .horizontal)
        dotButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        for label in [portLabel, frameLabel] {
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
        }
        portLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        frameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        baudButton.isBordered = false
        baudButton.setButtonType(.momentaryChange)
        baudButton.refusesFirstResponder = true
        baudButton.target = self
        baudButton.action = #selector(baudButtonClicked(_:))
        baudButton.toolTip = "Change baud rate (applies live)"
        baudButton.setContentHuggingPriority(.required, for: .horizontal)
        baudButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        hexBadge.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        hexBadge.textColor = .systemCyan
        hexBadge.isHidden = true
        hexBadge.toolTip = "Hex lens active"

        dtrChip.target = self
        dtrChip.action = #selector(dtrClicked)
        dtrChip.toolTip = "Toggle DTR"
        rtsChip.target = self
        rtsChip.action = #selector(rtsClicked)
        rtsChip.toolTip = "Toggle RTS"

        for counter in [txLabel, rxLabel] {
            counter.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            counter.textColor = .secondaryLabelColor
            counter.setContentHuggingPriority(.required, for: .horizontal)
            counter.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [dotButton, portLabel, baudButton, frameLabel,
                                        spacer, hexBadge, dtrChip, rtsChip,
                                        txLabel, rxLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        // "115200 8N1" — a thin space, no orphan hyphen (council #11).
        stack.setCustomSpacing(3, after: baudButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The footer is display-only chrome: it must never take the keyboard
    /// from the terminal.
    override var acceptsFirstResponder: Bool { false }

    // MARK: - Painting

    func update(state: SerialFooterModel.LinkState, portName: String,
                settings: SerialSettings, hexOn: Bool, lines: SerialModemLines?) {
        currentLinkState = state
        currentBaud = settings.baud
        let dotColor: NSColor
        switch state {
        case .connected: dotColor = .systemGreen
        case .reconnecting: dotColor = .systemOrange
        case .disconnected: dotColor = .tertiaryLabelColor
        case .userDisconnected: dotColor = .secondaryLabelColor
        }
        // Glyph + tooltip are model truths ("●"/"○"; the tooltip states the
        // ACTION — click to connect / click to disconnect).
        dotButton.attributedTitle = NSAttributedString(
            string: SerialFooterModel.dotGlyph(state),
            attributes: [.font: NSFont.systemFont(ofSize: 9),
                         .foregroundColor: dotColor])
        dotButton.toolTip = SerialFooterModel.dotTooltip(state)
        portLabel.stringValue = portName
        baudButton.toolTip = state == .connected
            ? "Change baud rate (applies live)"
            : "Change baud rate (applies on next connect)"
        // Council #11: blue is reserved for actual TOGGLE STATE (the filled
        // DTR/RTS chips). The baud is a click target, not a state — label
        // color, medium weight, tooltip carries the affordance.
        baudButton.attributedTitle = NSAttributedString(
            string: SerialFooterModel.baudText(settings),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                         .foregroundColor: NSColor.labelColor])
        frameLabel.stringValue = SerialFooterModel.frameText(settings)
        hexBadge.isHidden = !hexOn
        // Chips only where the device HAS modem lines and the port is open —
        // a pty/adapter without them degrades to no chips, never a guess.
        let showChips = state == .connected && lines != nil
        dtrChip.isHidden = !showChips
        rtsChip.isHidden = !showChips
        if let lines {
            dtrChip.setFilled(lines.dtr)
            rtsChip.setFilled(lines.rts)
        }
    }

    func updateCounters(tx: Int, rx: Int) {
        txLabel.stringValue = "TX \(SerialFooterModel.formatBytes(tx))"
        rxLabel.stringValue = "RX \(SerialFooterModel.formatBytes(rx))"
    }

    // Probe accessors (strip hit-test primitive family).
    var probeTxText: String { txLabel.stringValue }
    var probeRxText: String { rxLabel.stringValue }
    var probeBaudTitle: String { baudButton.attributedTitle.string }
    var probeFrameText: String { frameLabel.stringValue }
    var probeHexBadgeVisible: Bool { !hexBadge.isHidden }
    var probeDotTitle: String { dotButton.attributedTitle.string }
    var probeDotTooltip: String { dotButton.toolTip ?? "" }

    // MARK: - Baud menu

    private func makeBaudMenu() -> NSMenu {
        let menu = NSMenu(title: "Baud")
        for rate in SerialSettings.standardBauds {
            let item = NSMenuItem(title: "\(rate)",
                                  action: #selector(baudItemChosen(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = rate
            item.state = rate == currentBaud ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(title: "Custom…",
                                action: #selector(customBaudChosen(_:)),
                                keyEquivalent: "")
        custom.target = self
        menu.addItem(custom)
        return menu
    }

    @objc private func baudButtonClicked(_ sender: NSButton) {
        makeBaudMenu().popUp(positioning: nil,
                             at: NSPoint(x: 0, y: sender.bounds.height + 4),
                             in: sender)
    }

    @objc private func baudItemChosen(_ item: NSMenuItem) {
        guard let baud = item.representedObject as? Int else { return }
        onSelectBaud?(baud)
    }

    @objc private func customBaudChosen(_ item: NSMenuItem) {
        onCustomBaud?()
    }

    /// Test seam (gesture-path fidelity): selects a rate through the SAME
    /// menu item + action a human click travels — only the modal popUp is
    /// skipped, because a probe cannot dismiss a tracking menu.
    func probeSelectBaud(_ baud: Int) {
        guard let item = makeBaudMenu().items.first(where: {
            ($0.representedObject as? Int) == baud
        }) else { return }
        baudItemChosen(item)
    }

    @objc private func dtrClicked() { onToggleDTR?() }
    @objc private func rtsClicked() { onToggleRTS?() }
    @objc private func dotClicked() { onToggleConnection?() }
}
