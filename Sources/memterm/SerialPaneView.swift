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
    private(set) var isConnected = false
    /// Live-session unplug: the device vanished under an open connection.
    /// Standing consent — hotplug return auto-reopens.
    private(set) var awaitingDeviceReturn = false
    /// Restored pane (or failed open): reconnect needs the ⌘R gesture.
    var pendingReconnectOffer = false
    /// Hex lens (research: a live lens over the same stream, not a mode
    /// switch): incoming bytes render as offset+hex+ASCII rows from the
    /// toggle point forward; history above the divider stays as rendered.
    private(set) var hexMode = false
    private var hexFormatter = HexDumpFormatter()
    /// Fired when connect/disconnect state changes (title refresh).
    var onSerialStateChanged: (() -> Void)?

    init(setup: Setup, frame: NSRect, font: NSFont, options: TerminalOptions) {
        self.setup = setup
        super.init(frame: frame, font: font, options: options)
        paneTitle = SerialAdapter.paneTitle(path: setup.path, baud: setup.settings.baud)
        shellPath = nil
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
        try conn.open(settings: setup.settings)
        connection = conn
        isConnected = true
        awaitingDeviceReturn = false
        pendingReconnectOffer = false
        paneTitle = SerialAdapter.paneTitle(path: setup.path, baud: setup.settings.baud)
        onSerialStateChanged?()
    }

    /// Closes the connection without any banner (pane close / app teardown).
    func shutdown() {
        connection?.onDisconnect = nil
        connection?.close()
        connection = nil
        isConnected = false
    }

    /// EOF / vanished device on a LIVE session: banner + arm auto-reconnect.
    /// The buffer is never cleared — the gap is marked inline.
    private func handleDisconnect() {
        connection = nil
        isConnected = false
        awaitingDeviceReturn = true
        feedDim("memterm: device disconnected — will reconnect when it returns")
        onSerialStateChanged?()
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
            // Still enumerating / transiently busy: stay armed for the next
            // attach event rather than giving up silently.
            awaitingDeviceReturn = true
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
    private func ingest(_ data: Data) {
        if hexMode {
            var text = hexFormatter.append(data)
            if !text.isEmpty {
                text = text.replacingOccurrences(of: "\n", with: "\r\n")
                feed(text: text)
            }
        } else {
            feed(byteArray: ArraySlice([UInt8](data)))
        }
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
    }

    // MARK: - Line control (explicit user actions only — never on open)

    /// Current DTR/RTS/CTS/CD, nil where the device has no modem lines.
    func currentModemLines() -> SerialModemLines? {
        try? connection?.modemLines()
    }

    func toggleDTR() {
        withModemLines { lines, conn in
            try conn.setModemLine(dtr: !lines.dtr)
            self.feedDim("memterm: DTR \(!lines.dtr ? "asserted" : "deasserted")")
        }
    }

    func toggleRTS() {
        withModemLines { lines, conn in
            try conn.setModemLine(rts: !lines.rts)
            self.feedDim("memterm: RTS \(!lines.rts ? "asserted" : "deasserted")")
        }
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
