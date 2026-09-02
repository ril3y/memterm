import AppKit
import MemtermCore
import SwiftTerm

// A pane whose byte source is a SerialConnection instead of a shell
// (feature/serial UX stage). Built on the LocalProcessTerminalView seam
// verified in SwiftTerm: keystrokes arrive through the TerminalViewDelegate's
// open `send(source:data:)` (which LocalProcessTerminalView routes to its
// LocalProcess) — overridden here to route to the serial fd instead; incoming
// bytes are feed()'d. The inherited LocalProcess is never started, so every
// process-shaped code path (poll guard, close/terminate, FR-56 checks) sees
// `process.running == false` and stays inert. Subclassing PaneView (not bare
// TerminalView) keeps serial panes first-class in the pane tree: splits,
// tabs, workspaces, capture, find, and the context menu all work unchanged.
//
// Consent rules in force here:
//  - connect() only ever runs behind an explicit user action (Connect button,
//    ⌘R reconnect gesture) — EXCEPT the live-session hotplug return, where
//    the user's original open is standing consent (tio-style auto-reconnect;
//    the restore boundary never auto-opens).
//  - The reconnect offer performs a reconnect ACTION; no shell command is
//    composed or typed, so the denylist path is untouched.

final class SerialPaneView: PaneView {

    /// Everything needed to open (or re-open) the session.
    struct Setup {
        var path: String
        var identity: String
        var label: String
        var settings: SerialSettings
        var txLineEnding: SerialLineEnding
        var localEcho: Bool

        var offer: SerialAdapter.ReconnectOffer {
            SerialAdapter.ReconnectOffer(path: path, identity: identity, label: label,
                                         settings: settings, txLineEnding: txLineEnding,
                                         localEcho: localEcho)
        }
    }

    private(set) var setup: Setup
    private var connection: SerialConnection?
    /// The connection lifecycle — one pure machine (MemtermCore) owns the
    /// transition rules; every flag below derives from it. The load-bearing
    /// distinction: a USER disconnect suppresses hotplug auto-reopen (a
    /// deliberate release must never steal the port back mid-flash), while
    /// a device-vanished loss keeps the tio-style auto-reopen armed.
    private(set) var link = SerialLinkStateMachine()
    var isConnected: Bool { link.isConnected }
    /// Live-session unplug: the device vanished under an open connection.
    /// Standing consent — hotplug return auto-reopens.
    var awaitingDeviceReturn: Bool { link.shouldAutoReopenOnHotplug }
    /// Restored pane (or failed open): reconnect needs the ⌘R gesture.
    var pendingReconnectOffer = false
    /// Hex lens (research: a live lens over the same stream, not a mode
    /// switch): incoming bytes render as offset+hex+ASCII rows from the
    /// toggle point forward; history above the divider stays as rendered.
    private(set) var hexMode = false
    private var hexFormatter = HexDumpFormatter()
    /// Fired when connect/disconnect state changes (title refresh).
    var onSerialStateChanged: (() -> Void)?

    // -- Footer bar (SerialFooterModel owns the logic; the strip is thin) --
    /// Lifetime TX/RX counters + repaint throttle. Lives on the PANE, so the
    /// counts survive reconnects by construction.
    private(set) var footerModel = SerialFooterModel()
    private(set) var footerView: SerialFooterView?
    private var footerFlushTimer: Timer?
    /// Test seam (ptys answer every modem-line ioctl with ENOTTY): when set,
    /// DTR/RTS reads and toggles go through this stub instead of the fd, so
    /// the probe can drive the chip gesture end to end. nil in real use.
    var probeModemLinesStub: SerialModemLines?

    /// Test seam (reconnect-keeps-counters leg): rebinds the device path
    /// exactly as hotplugAttached does when /dev renumbers on return, so the
    /// probe's second pty can stand in for a returning device before it
    /// drives the same connect() every reconnect path funnels through.
    func probeRebindPath(_ path: String) {
        setup.path = path
    }

    init(setup: Setup, frame: NSRect, font: NSFont, options: TerminalOptions) {
        self.setup = setup
        super.init(frame: frame, font: font, options: options)
        paneTitle = SerialAdapter.paneTitle(path: setup.path, baud: setup.settings.baud)
        shellPath = nil
        installFooter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { shutdown() }

    // MARK: - Connect / disconnect

    private static let dividerDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d h:mm a"
        return f
    }()

    /// Opens the device with the pane's settings and starts pumping. Throws
    /// SerialError; callers surface failures as dim feed lines.
    func connect() throws {
        guard !isConnected else { return }
        let conn = SerialConnection(path: setup.path)
        conn.onData = { [weak self] data in self?.ingest(data) }
        conn.onDisconnect = { [weak self] in self?.handleDisconnect() }
        conn.onTraffic = { [weak self] rx, tx in self?.noteTraffic(rx: rx, tx: tx) }
        try conn.open(settings: setup.settings)
        connection = conn
        link.didConnect()
        pendingReconnectOffer = false
        paneTitle = SerialAdapter.paneTitle(path: setup.path, baud: setup.settings.baud)
        onSerialStateChanged?()
        refreshFooter()
    }

    /// Closes the connection without any banner (pane close / app teardown).
    /// FR-56 semantics live with the CALLER (closing the pane forgets); this
    /// is just fd teardown.
    func shutdown() {
        connection?.onDisconnect = nil
        connection?.close()
        connection = nil
        link = SerialLinkStateMachine()
        footerFlushTimer?.invalidate()
        footerFlushTimer = nil
    }

    /// The deliberate USER release (footer dot toggle / context-menu
    /// Disconnect): close the fd so esptool/avrdude can take the port, keep
    /// pane, scrollback, and counters, and SUPPRESS hotplug auto-reopen —
    /// the machine's userDisconnected state is what hotplugAttached checks,
    /// so a mid-flash device blip can never steal the port back.
    /// Disconnect ≠ close: nothing here touches the journal or the pane.
    func performDisconnectGesture() {
        guard isConnected else { return }
        connection?.onDisconnect = nil
        connection?.close()
        connection = nil
        link.userDisconnect()
        feedDim("memterm: port released")
        onSerialStateChanged?()
        refreshFooter()
    }

    /// The explicit Connect gesture (footer dot toggle / context-menu
    /// Connect): reopen with the CURRENT settings — the user may have edited
    /// baud/flow while disconnected, and those pending settings are exactly
    /// what the founder's wrong-baud scenario needs applied on reopen.
    func performConnectGesture() {
        guard !isConnected else { return }
        // Prefer the identity-matched node when discovery knows the device —
        // /dev may have renumbered while the port was released for flashing.
        // Ptys and absent devices simply keep the recorded path.
        if let port = match(in: SerialPortDiscovery.enumeratePorts()) {
            setup.path = port.path
        }
        do {
            try connect()
            feedDim("memterm: connected @ \(setup.settings.compactString)")
        } catch {
            feedDim("memterm: could not open \(setup.path) (\(Self.describe(error)))")
        }
    }

    /// The footer dot's toggle action: one click, the opposite state.
    func toggleConnectionGesture() {
        if isConnected {
            performDisconnectGesture()
        } else {
            performConnectGesture()
        }
    }

    /// EOF / vanished device on a LIVE session: banner + arm auto-reconnect.
    /// The buffer is never cleared — the gap is marked inline.
    private func handleDisconnect() {
        connection = nil
        link.deviceLost()
        feedDim("memterm: device disconnected — will reconnect when it returns")
        onSerialStateChanged?()
        refreshFooter()
    }

    /// IOKit terminated notification for this pane's device. The read pump's
    /// EOF usually beats this, but some drivers error out of read(2) without
    /// an EOF — the notification closes the gap either way (idempotent).
    func hotplugDetached(_ ports: [SerialPortInfo]) {
        guard isConnected, matches(ports) else { return }
        connection?.onDisconnect = nil
        connection?.close()
        handleDisconnect()
    }

    /// Hotplug return of a device this LIVE session was using: auto-reopen
    /// (standing consent — see header) and mark the gap with a divider line.
    func hotplugAttached(_ ports: [SerialPortInfo]) {
        guard awaitingDeviceReturn, let port = match(in: ports) else { return }
        setup.path = port.path  // /dev may have renumbered; identity matched
        do {
            try connect()
            let stamp = Self.dividerDateFormatter.string(from: Date())
            feed(text: "\u{1b}[36m── reconnected — \(stamp) ──\u{1b}[0m\r\n")
        } catch {
            // Still enumerating / transiently busy: the machine is still in
            // reconnectingAfterLoss (a failed open never transitions), so we
            // stay armed for the next attach event rather than giving up.
            feedDim("memterm: reconnect failed (\(Self.describe(error))) — still waiting")
        }
    }

    /// The ⌘R gesture (and the offer flow): reconnect NOW if the device is
    /// present, honest line when it isn't. Never types a command.
    func performReconnectGesture() {
        guard !isConnected else { return }
        let ports = SerialPortDiscovery.enumeratePorts()
        guard let port = match(in: ports) else {
            feedDim("memterm: device not connected — \(setup.offer.displayName)")
            return  // offer stays pending; ⌘R can retry after a plug-in
        }
        setup.path = port.path
        do {
            try connect()
            let stamp = Self.dividerDateFormatter.string(from: Date())
            feed(text: "\u{1b}[36m── reconnected — \(stamp) ──\u{1b}[0m\r\n")
        } catch {
            pendingReconnectOffer = true
            feedDim("memterm: could not open \(setup.path) (\(Self.describe(error))) — press ⌘R to retry")
        }
    }

    private func matches(_ ports: [SerialPortInfo]) -> Bool {
        match(in: ports) != nil
    }

    /// Reconnect keys on stable identity first (vid/pid/serial survives /dev
    /// renumbering), exact path as the fallback for pty/test devices.
    private func match(in ports: [SerialPortInfo]) -> SerialPortInfo? {
        ports.first { $0.stableIdentity == setup.identity }
            ?? ports.first { $0.path == setup.path }
    }

    // MARK: - RX (feed) / TX (send override)

    /// Incoming bytes, on the main queue (SerialConnection's callbackQueue).
    /// SCROLL UX: allowMouseReporting syncs on both sides of the feed, same
    /// contract as PaneView.dataReceived — serial streams must not clear a
    /// selection either.
    private func ingest(_ data: Data) {
        syncAllowMouseReporting()
        if hexMode {
            var text = hexFormatter.append(data)
            if !text.isEmpty {
                text = text.replacingOccurrences(of: "\n", with: "\r\n")
                feed(text: text)
            }
        } else {
            feed(byteArray: ArraySlice([UInt8](data)))
        }
        syncAllowMouseReporting()
        onOutputActivity?()
    }

    /// The TerminalViewDelegate send path — every keystroke lands here (the
    /// exact seam LocalProcessTerminalView routes into LocalProcess.send).
    /// Ctrl-C and friends pass through as plain bytes; only CR is rewritten
    /// per the TX line-ending setting.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard let conn = connection, isConnected else {
            NSSound.beep()
            return
        }
        let out = setup.txLineEnding.transformOutgoing(Array(data))
        if setup.localEcho {
            // Echo the ORIGINAL keystroke bytes (UTF-8 intact; CR shown as a
            // newline).
            var display: [UInt8] = []
            for b in data {
                if b == 0x0D { display.append(contentsOf: [0x0D, 0x0A]) }
                else { display.append(b) }
            }
            feed(byteArray: ArraySlice(display))
        }
        guard !out.isEmpty else { return }
        do {
            try conn.write(Data(out))
        } catch {
            feedDim("memterm: serial write failed (\(Self.describe(error)))")
        }
    }

    /// Raw TX for the "Send Hex…" sheet: no line-ending transform, and the
    /// sent bytes echo as a dim line so the action is visible in the stream.
    func writeRaw(_ bytes: [UInt8]) {
        guard let conn = connection, isConnected else {
            feedDim("memterm: not connected — press ⌘R to reconnect")
            return
        }
        do {
            try conn.write(Data(bytes))
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            feedDim("memterm: sent \(bytes.count) byte\(bytes.count == 1 ? "" : "s"): \(hex)")
        } catch {
            feedDim("memterm: serial write failed (\(Self.describe(error)))")
        }
    }

    // MARK: - Hex lens

    /// Toggle re-renders only from this point forward; a divider marks the
    /// switch. Offsets restart at 0 at each toggle (the lens documents the
    /// stream from here, not the session's absolute byte count).
    func setHexMode(_ on: Bool) {
        guard on != hexMode else { return }
        if hexMode {
            let tail = hexFormatter.flush()
            if !tail.isEmpty {
                feed(text: tail.replacingOccurrences(of: "\n", with: "\r\n"))
            }
        }
        hexMode = on
        hexFormatter = HexDumpFormatter()
        feed(text: "\u{1b}[36m── hex view \(on ? "on" : "off") ──\u{1b}[0m\r\n")
        refreshFooter()
    }

    // MARK: - Line control (explicit user actions only — never on open)

    /// Current DTR/RTS/CTS/CD, nil where the device has no modem lines.
    func currentModemLines() -> SerialModemLines? {
        if let stub = probeModemLinesStub { return isConnected ? stub : nil }
        return try? connection?.modemLines()
    }

    func toggleDTR() {
        if let stub = probeModemLinesStub {  // test seam — see declaration
            probeModemLinesStub = SerialModemLines(dtr: !stub.dtr, rts: stub.rts,
                                                   cts: stub.cts,
                                                   carrierDetect: stub.carrierDetect)
            feedDim("memterm: DTR \(!stub.dtr ? "asserted" : "deasserted")")
            refreshFooter()
            return
        }
        withModemLines { lines, conn in
            try conn.setModemLine(dtr: !lines.dtr)
            self.feedDim("memterm: DTR \(!lines.dtr ? "asserted" : "deasserted")")
        }
        refreshFooter()
    }

    func toggleRTS() {
        if let stub = probeModemLinesStub {  // test seam — see declaration
            probeModemLinesStub = SerialModemLines(dtr: stub.dtr, rts: !stub.rts,
                                                   cts: stub.cts,
                                                   carrierDetect: stub.carrierDetect)
            feedDim("memterm: RTS \(!stub.rts ? "asserted" : "deasserted")")
            refreshFooter()
            return
        }
        withModemLines { lines, conn in
            try conn.setModemLine(rts: !lines.rts)
            self.feedDim("memterm: RTS \(!lines.rts ? "asserted" : "deasserted")")
        }
        refreshFooter()
    }

    func sendBreakSignal() {
        guard let conn = connection, isConnected else { return }
        do {
            try conn.sendBreak()
            feedDim("memterm: break sent")
        } catch {
            feedDim("memterm: break not supported (\(Self.describe(error)))")
        }
    }

    /// "Reset Board": the deliberate ESP32/Arduino reset pulse — EN (RTS)
    /// pulled low for 100 ms with IO0 (DTR) released. Explicit menu action
    /// only; memterm never touches these lines implicitly (research: boards
    /// reset or hang on naive opens).
    func resetBoard() {
        guard let conn = connection, isConnected else { return }
        do {
            try conn.setModemLine(dtr: false, rts: true)   // EN low, IO0 high
            feedDim("memterm: reset pulse — EN low")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.connection === conn else { return }
                do {
                    try conn.setModemLine(rts: false)      // EN released — boot
                    self.feedDim("memterm: reset pulse — EN released, board booting")
                } catch {
                    self.feedDim("memterm: reset failed (\(Self.describe(error)))")
                }
            }
        } catch {
            feedDim("memterm: reset not supported (\(Self.describe(error)))")
        }
    }

    private func withModemLines(_ body: (SerialModemLines, SerialConnection) throws -> Void) {
        guard let conn = connection, isConnected else { return }
        do {
            let lines = try conn.modemLines()
            try body(lines, conn)
        } catch SerialError.lineControlUnsupported {
            feedDim("memterm: this device has no modem lines")
        } catch {
            feedDim("memterm: line control failed (\(Self.describe(error)))")
        }
    }

    // MARK: - Footer bar (state dot · port · settings · counters · chips)

    private func installFooter() {
        let footer = SerialFooterView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.onSelectBaud = { [weak self] baud in self?.applyBaud(baud) }
        footer.onCustomBaud = { [weak self] in self?.promptCustomBaud() }
        footer.onToggleConnection = { [weak self] in self?.toggleConnectionGesture() }
        footer.onToggleDTR = { [weak self] in self?.toggleDTR() }
        footer.onToggleRTS = { [weak self] in self?.toggleRTS() }
        addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: SerialFooterView.barHeight),
        ])
        footerView = footer
        // SCROLL UX: the overlay scroll band stops above the footer strip.
        scrollerBottomInset = SerialFooterView.barHeight
        refreshFooter()
        footer.updateCounters(tx: footerModel.txBytes, rx: footerModel.rxBytes)
    }

    /// Repaints everything but the counters (those ride the throttle).
    func refreshFooter() {
        footerView?.update(
            state: SerialFooterModel.linkState(link),
            portName: SerialAdapter.shortName(forPath: setup.path),
            settings: setup.settings, hexOn: hexMode, lines: currentModemLines())
    }

    /// SerialConnection's onTraffic hook (main queue). The model throttles
    /// repaints to ≤4 Hz; a one-shot trailing timer flushes whatever a burst
    /// left unpainted, so the counters always settle on the true totals.
    private func noteTraffic(rx: Int, tx: Int) {
        if footerModel.recordTraffic(rx: rx, tx: tx,
                                     now: ProcessInfo.processInfo.systemUptime) {
            footerView?.updateCounters(tx: footerModel.txBytes, rx: footerModel.rxBytes)
        } else if footerFlushTimer == nil {
            footerFlushTimer = Timer.scheduledTimer(withTimeInterval: footerModel.minInterval,
                                                    repeats: false) { [weak self] _ in
                guard let self else { return }
                self.footerFlushTimer = nil
                if self.footerModel.flushPendingRepaint(now: ProcessInfo.processInfo.systemUptime) {
                    self.footerView?.updateCounters(tx: self.footerModel.txBytes,
                                                    rx: self.footerModel.rxBytes)
                }
            }
        }
    }

    /// Footer baud menu selection: re-applies termios on the LIVE fd
    /// (picocom-style — the port never closes). On failure the old settings
    /// stand and the failure surfaces as a dim line.
    func applyBaud(_ baud: Int) {
        guard baud > 0 else { return }
        var settings = setup.settings
        settings.baud = baud
        applyLiveSettings(settings)
    }

    /// The general half of applyBaud, for any settings change from footer or
    /// future UI. Disconnected panes just adopt the settings for the next
    /// open (the journal picks them up on the next poll).
    func applyLiveSettings(_ newSettings: SerialSettings) {
        guard newSettings != setup.settings else { return }
        if isConnected, let conn = connection {
            do {
                try conn.apply(settings: newSettings)
                feedDim("memterm: line settings now \(newSettings.compactString) (applied live)")
            } catch {
                feedDim("memterm: could not apply \(newSettings.compactString) (\(Self.describe(error))) — keeping \(setup.settings.compactString)")
                refreshFooter()
                return
            }
        }
        setup.settings = newSettings
        paneTitle = SerialAdapter.paneTitle(path: setup.path, baud: newSettings.baud)
        onSerialStateChanged?()
        refreshFooter()
    }

    /// "Custom…" in the footer's baud menu: one numeric field, sheet on the
    /// pane's window (the promptSendHex pattern).
    private func promptCustomBaud() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Custom Baud Rate"
        alert.informativeText = "Applied live to the open port. Non-standard rates use the driver's arbitrary-rate path."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        field.placeholderString = "\(setup.settings.baud)"
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        alert.accessoryView = field
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard let baud = Int(text), baud > 0 else {
                if !text.isEmpty { self.feedDim("memterm: not a baud rate: \(text)") }
                return
            }
            self.applyBaud(baud)
        }
    }

    /// Test seam: termios readback off the live fd, so the probe can assert
    /// a footer baud change actually reached the kernel (nil when closed).
    func currentTermiosForProbe() -> termios? {
        try? connection?.currentTermios()
    }

    // MARK: - Journal / restore support

    /// adapter_state for the 2 s capture poll: identity + settings survive so
    /// the restored pane can offer the consent-gated reconnect.
    func adapterStateForJournal() -> [String: String] {
        SerialAdapter.journalState(path: setup.path, identity: setup.identity,
                                   label: setup.label, settings: setup.settings,
                                   txLineEnding: setup.txLineEnding,
                                   localEcho: setup.localEcho)
    }

    /// Feed lens toggles from the connect sheet / menus.
    func updateLocalEcho(_ on: Bool) { setup.localEcho = on }
    func updateTxLineEnding(_ ending: SerialLineEnding) { setup.txLineEnding = ending }

    // MARK: -

    func feedDim(_ text: String) {
        feed(text: "\u{1b}[2m" + text + "\u{1b}[0m\r\n")
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case SerialError.busy: return "port is busy"
        case SerialError.vanished: return "device vanished"
        case SerialError.permissionDenied: return "permission denied"
        case SerialError.notOpen: return "not open"
        case SerialError.lineControlUnsupported: return "not supported"
        case SerialError.writeTimeout: return "write timed out"
        case SerialError.invalidSettings(let s): return "invalid settings: \(s)"
        case SerialError.io(let errno): return "I/O error \(errno)"
        default: return "\(error)"
        }
    }
}
