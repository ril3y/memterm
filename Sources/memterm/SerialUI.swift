import AppKit
import MemtermCore

// The "New Serial Connection…" sheet (feature/serial UX). Progressive
// disclosure per the research: port + baud + Connect visible; framing/flow
// behind "More Options"; TX line ending + local echo inline (they are the two
// things Arduino users flip daily). Live port list via the app's hotplug
// watcher; per-device profiles (journaled by stable identity) pre-fill what
// worked last time. Auto-baud is an honest explicit button: it opens the
// port, samples the ladder, and REPORTS a guess — the user accepts by
// leaving the filled-in value or overrides it; nothing is adopted silently.

final class SerialConnectSheetController: NSObject {

    /// Test hook (MEMTERM_SERIAL_PROBE_PTY): an extra fake "port" row so the
    /// UI probe and manual testing can exercise the flow on a pty slave
    /// without hardware.
    static func probePtyPort() -> SerialPortInfo? {
        guard let path = ProcessInfo.processInfo.environment["MEMTERM_SERIAL_PROBE_PTY"],
              !path.isEmpty else { return nil }
        return SerialPortInfo(path: path)
    }

    private unowned let app: MemtermAppDelegate
    private let sheet: NSWindow
    private weak var host: NSWindow?

    private let portPopUp = NSPopUpButton()
    private let pathCaption = NSTextField(labelWithString: "")
    private let baudCombo = NSComboBox()
    private let detectButton = NSButton(title: "Detect", target: nil, action: nil)
    private let detectCaption = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "More Options", target: nil, action: nil)
    private let dataBitsPopUp = NSPopUpButton()
    private let parityPopUp = NSPopUpButton()
    private let stopBitsPopUp = NSPopUpButton()
    private let flowPopUp = NSPopUpButton()
    private let lineEndingPopUp = NSPopUpButton()
    private let echoCheck = NSButton(checkboxWithTitle: "Local echo", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private var framingRow: [NSView] = []
    private var grid: NSGridView?

    private var ports: [SerialPortInfo] = []
    private var detecting = false

    /// Fired with the composed setup when the user clicks Connect.
    var onConnect: ((SerialPaneView.Setup) -> Void)?

    init(app: MemtermAppDelegate) {
        self.app = app
        sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 100),
                         styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "New Serial Connection"
        super.init()
        buildForm()
        reloadPorts(preservingSelection: false)
    }

    // MARK: - Form

    private func caption(_ field: NSTextField) {
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
    }

    private func buildForm() {
        portPopUp.target = self
        portPopUp.action = #selector(portChanged)
        caption(pathCaption)
        caption(detectCaption)
        detectCaption.stringValue = ""

        baudCombo.usesDataSource = false
        baudCombo.completes = true
        for baud in SerialSettings.standardBauds { baudCombo.addItem(withObjectValue: "\(baud)") }
        baudCombo.stringValue = "115200"
        baudCombo.widthAnchor.constraint(equalToConstant: 110).isActive = true

        detectButton.target = self
        detectButton.action = #selector(detectBaud)
        detectButton.bezelStyle = .rounded
        detectButton.controlSize = .small
        detectButton.toolTip = "Cycle common rates and score what the device is sending — a guess to accept or override, only useful while the device is chattering"

        moreButton.target = self
        moreButton.action = #selector(toggleMore)
        moreButton.bezelStyle = .inline
        moreButton.controlSize = .small
        // Council #11: a real disclosure chevron — the bare text button did
        // not read as expandable.
        moreButton.image = NSImage(systemSymbolName: "chevron.right",
                                   accessibilityDescription: "Show more options")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        moreButton.imagePosition = .imageLeading

        dataBitsPopUp.addItems(withTitles: ["5", "6", "7", "8"])
        dataBitsPopUp.selectItem(withTitle: "8")
        parityPopUp.addItems(withTitles: ["None", "Even", "Odd"])
        stopBitsPopUp.addItems(withTitles: ["1", "2"])
        flowPopUp.addItems(withTitles: ["None", "RTS/CTS", "XON/XOFF"])

        lineEndingPopUp.addItems(withTitles: SerialLineEnding.labels)
        selectLineEnding(app.config.serialTxLineEnding)
        echoCheck.state = app.config.serialLocalEcho ? .on : .off

        connectButton.target = self
        connectButton.action = #selector(connectAction)
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "Cancel", target: self,
                                    action: #selector(cancelAction))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

        let baudRow = NSStackView(views: [baudCombo, detectButton])
        baudRow.orientation = .horizontal

        let framing = NSStackView(views: [dataBitsPopUp, parityPopUp, stopBitsPopUp,
                                          label("Flow:"), flowPopUp])
        framing.orientation = .horizontal
        framing.spacing = 6

        let txRow = NSStackView(views: [lineEndingPopUp, echoCheck])
        txRow.orientation = .horizontal
        txRow.spacing = 12

        let buttonRow = NSStackView(views: [cancelButton, connectButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let grid = NSGridView(views: [
            [label("Port:"), portPopUp],
            [NSGridCell.emptyContentView, pathCaption],
            [label("Baud:"), baudRow],
            [NSGridCell.emptyContentView, detectCaption],
            [label("Line ending:"), txRow],
            [NSGridCell.emptyContentView, moreButton],
            [label("Framing:"), framing],
            [NSGridCell.emptyContentView, buttonRow],
        ])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        self.grid = grid
        grid.row(at: 6).isHidden = true  // framing behind "More Options"
        portPopUp.widthAnchor.constraint(equalToConstant: 280).isActive = true
        pathCaption.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true
        detectCaption.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor,
                                           constant: -16),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        sheet.contentView = content
        sheet.setContentSize(content.fittingSize)
    }

    // MARK: - Ports

    /// Called at open and on every hotplug attach/detach: friendly labels,
    /// /dev path as the caption under the popup.
    func reloadPorts(preservingSelection: Bool = true) {
        let selectedIdentity = preservingSelection ? selectedPort()?.stableIdentity : nil
        ports = SerialPortDiscovery.enumeratePorts()
            .sorted { ($0.isUSB ? 0 : 1, $0.label) < ($1.isUSB ? 0 : 1, $1.label) }
        if let fake = Self.probePtyPort() { ports.append(fake) }
        portPopUp.removeAllItems()
        if ports.isEmpty {
            portPopUp.addItem(withTitle: "No serial devices found")
        }
        for port in ports {
            var title = port.label
            if let serial = port.usbSerialNumber, !serial.isEmpty,
               !title.contains(serial) {
                title += " (\(serial))"
            }
            portPopUp.addItem(withTitle: title)
            portPopUp.lastItem?.toolTip = port.path
        }
        if let selectedIdentity,
           let index = ports.firstIndex(where: { $0.stableIdentity == selectedIdentity }) {
            portPopUp.selectItem(at: index)
        }
        portChanged(nil)
    }

    private func selectedPort() -> SerialPortInfo? {
        let index = portPopUp.indexOfSelectedItem
        guard ports.indices.contains(index) else { return nil }
        return ports[index]
    }

    /// Selecting a device loads its remembered profile (per-device memory —
    /// the journal, not a hidden pref).
    @objc private func portChanged(_ sender: Any?) {
        connectButton.isEnabled = !ports.isEmpty
        guard let port = selectedPort() else {
            pathCaption.stringValue = "Plug in a USB-serial device — the list updates live."
            return
        }
        pathCaption.stringValue = port.path
        guard let profile = app.memory?.store.serialProfile(identity: port.stableIdentity),
              let settings = SerialSettings.parse(profile.settings) else { return }
        baudCombo.stringValue = "\(settings.baud)"
        dataBitsPopUp.selectItem(withTitle: "\(settings.dataBits)")
        parityPopUp.selectItem(at: [SerialSettings.Parity.none, .even, .odd]
            .firstIndex(of: settings.parity) ?? 0)
        stopBitsPopUp.selectItem(withTitle: "\(settings.stopBits)")
        flowPopUp.selectItem(at: [SerialSettings.FlowControl.none, .rtscts, .xonxoff]
            .firstIndex(of: settings.flow) ?? 0)
        selectLineEnding(profile.txLineEnding)
        echoCheck.state = profile.localEcho ? .on : .off
        if settings != SerialSettings(baud: settings.baud) {
            setFramingRowVisible(true)  // non-8N1 profile: show framing
        }
    }

    private func selectLineEnding(_ raw: String) {
        if let index = SerialLineEnding.configValues.firstIndex(of: raw) {
            lineEndingPopUp.selectItem(at: index)
        }
    }

    // MARK: - Values

    private func composedSettings() -> SerialSettings? {
        let baudText = baudCombo.stringValue.trimmingCharacters(in: .whitespaces)
        guard let baud = Int(baudText), baud > 0, baud <= 10_000_000 else { return nil }
        let parity = [SerialSettings.Parity.none, .even, .odd][
            max(0, parityPopUp.indexOfSelectedItem)]
        let flow = [SerialSettings.FlowControl.none, .rtscts, .xonxoff][
            max(0, flowPopUp.indexOfSelectedItem)]
        return SerialSettings(baud: baud,
                              dataBits: Int(dataBitsPopUp.titleOfSelectedItem ?? "8") ?? 8,
                              parity: parity,
                              stopBits: Int(stopBitsPopUp.titleOfSelectedItem ?? "1") ?? 1,
                              flow: flow)
    }

    private func composedLineEnding() -> SerialLineEnding {
        let index = lineEndingPopUp.indexOfSelectedItem
        guard SerialLineEnding.configValues.indices.contains(index),
              let ending = SerialLineEnding(rawValue: SerialLineEnding.configValues[index])
        else { return .crlf }
        return ending
    }

    // MARK: - Actions

    @objc private func toggleMore(_ sender: Any?) {
        guard let grid else { return }
        setFramingRowVisible(grid.row(at: 6).isHidden)
    }

    /// One place flips the disclosure (click AND the non-8N1-profile auto-
    /// reveal) so the chevron, title, and sheet size never disagree.
    private func setFramingRowVisible(_ visible: Bool) {
        guard let grid else { return }
        grid.row(at: 6).isHidden = !visible
        moreButton.title = visible ? "Fewer Options" : "More Options"
        moreButton.image = NSImage(
            systemSymbolName: visible ? "chevron.down" : "chevron.right",
            accessibilityDescription: visible ? "Show fewer options"
                                              : "Show more options")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        sheet.setContentSize(sheet.contentView?.fittingSize ?? sheet.frame.size)
    }

    /// Honest auto-baud: opens the port (this click is the consent), samples
    /// the candidate ladder, reports a ranked guess inline. Detection can
    /// only work while the device is transmitting; silence says so plainly.
    @objc private func detectBaud(_ sender: Any?) {
        guard !detecting, let port = selectedPort() else { return }
        guard let base = composedSettings() ?? SerialSettings.parse("115200-8N1") else { return }
        detecting = true
        detectButton.isEnabled = false
        detectCaption.stringValue = "Listening on each rate…"
        let path = port.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var report: String
            var pick: Int?
            let connection = SerialConnection(path: path,
                                              callbackQueue: DispatchQueue(label: "memterm.serial.detect"))
            do {
                try connection.open(settings: base)
                let result = try SerialAutoBaud.probe(connection: connection,
                                                      baseSettings: base, window: 0.35)
                switch result {
                case .likely(let rate, let confidence, _):
                    pick = rate
                    report = String(format: "Looks like %d (%.0f%% match) — filled in; change it if that's wrong.",
                                    rate, confidence * 100)
                case .inconclusive(let ranking):
                    let top = ranking.prefix(3)
                        .map { String(format: "%d (%.0f%%)", $0.rate, $0.confidence * 100) }
                        .joined(separator: ", ")
                    report = "Unclear — best guesses: \(top). Pick manually."
                case .noData:
                    report = "No data received — detection only works while the device is sending."
                }
            } catch {
                report = "Couldn't open port: \(SerialPaneView.describe(error))"
            }
            connection.close()
            DispatchQueue.main.async {
                guard let self else { return }
                self.detecting = false
                self.detectButton.isEnabled = true
                self.detectCaption.stringValue = report
                if let pick { self.baudCombo.stringValue = "\(pick)" }
            }
        }
    }

    @objc private func connectAction(_ sender: Any?) {
        guard let port = selectedPort() else { return }
        guard let settings = composedSettings() else {
            detectCaption.stringValue = "Enter a numeric baud rate (e.g. 115200)."
            return
        }
        let ending = composedLineEnding()
        let echo = echoCheck.state == .on
        let setup = SerialPaneView.Setup(path: port.path,
                                         identity: port.stableIdentity,
                                         label: port.label,
                                         settings: settings,
                                         txLineEnding: ending,
                                         localEcho: echo)
        // Per-device memory: remember what the user connected with.
        app.memory?.store.upsertSerialProfile(SerialProfileRow(
            identity: port.stableIdentity, settings: settings.compactString,
            txLineEnding: ending.rawValue, localEcho: echo,
            lastPath: port.path, label: port.label))
        endSheet()
        onConnect?(setup)
    }

    @objc private func cancelAction(_ sender: Any?) {
        endSheet()
    }

    // MARK: - Present / dismiss

    func present(on window: NSWindow) {
        host = window
        reloadPorts(preservingSelection: false)
        window.beginSheet(sheet)
    }

    private func endSheet() {
        host?.endSheet(sheet)
        sheet.orderOut(nil)
        app.serialSheetClosed(self)
    }
}
