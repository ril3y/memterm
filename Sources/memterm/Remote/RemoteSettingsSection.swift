import AppKit
import CoreImage
import MemtermCore

// Settings ▸ Remote (decision doc 2026-09-19): the only place remote attach
// can be turned on, the only place a device can be paired, and the only place
// one can be revoked. It owns its own controls and writes its own two config
// keys, so SettingsWindowController just asks it for rows.
//
// The pairing flow is deliberately two-sided: the QR carries a single-use
// token with a two-minute life, and the Mac STILL asks "Allow ‹name›?" before
// storing the device's key. A photographed QR alone is not access.

final class RemoteSettingsSection: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private unowned let app: MemtermAppDelegate
    private var host: RemoteHost { app.remote }

    private let enableCheck = NSButton(
        checkboxWithTitle: "Let paired devices see and type into these sessions",
        target: nil, action: nil)
    private let relayField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    /// The origin a QR code would actually open (security re-review N1).
    /// Read-only and selectable: there is nothing to edit here — `web_url`
    /// lives in config.toml — but there is something to CHECK, and it is
    /// the single most consequential value in this pane.
    private let pageLabel = NSTextField(labelWithString: "")
    private let pairButton = NSButton(title: "Pair a device…", target: nil, action: nil)
    private let deviceTable = NSTableView()
    private let deviceScroll = NSScrollView()

    /// The open QR sheet, if any, plus the token's deadline and the ticker
    /// that counts it down.
    private var pairingSheet: NSWindow?
    private var pairingDeadline: Date?
    private var countdownTimer: Timer?
    private let countdownLabel = NSTextField(labelWithString: "")

    private var devices: [PairedDevice] = []

    init(app: MemtermAppDelegate) {
        self.app = app
        super.init()
        enableCheck.target = self
        enableCheck.action = #selector(controlChanged)
        relayField.target = self
        relayField.action = #selector(controlChanged)
        relayField.placeholderString = "wss://memterm-relay.fly.dev"
        pairButton.bezelStyle = .rounded
        pairButton.target = self
        pairButton.action = #selector(pairAction)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        pageLabel.font = NSFont.systemFont(ofSize: 11)
        pageLabel.textColor = .secondaryLabelColor
        // Selectable so the user can copy it somewhere and compare, and
        // truncating in the middle so a long path never hides the HOST,
        // which is the part that matters.
        pageLabel.isSelectable = true
        pageLabel.lineBreakMode = .byTruncatingMiddle
        buildDeviceTable()
        attach()
    }

    deinit {
        countdownTimer?.invalidate()
    }

    /// Settings is open: answer pair requests and follow the host's state.
    ///
    /// Called on every `show()`, not just at construction, because the window
    /// controller and this section are cached for the app's life — without
    /// re-arming, the first close would silently disable pairing for the rest
    /// of the session (every later request hitting the host's auto-deny).
    /// Installing the same closures twice is harmless: they replace, not
    /// accumulate.
    func attach() {
        // The host denies a pair request outright when nobody is prompting,
        // so this hookup IS the consent path: pairing only works while the
        // user is looking at this section.
        host.onPairRequest = { [weak self] name, deviceId, spki, accept in
            // A section that has gone away answers the same way a closed
            // Settings window does — deny — rather than leaving the device
            // waiting on a prompt nobody will ever show.
            guard let self else {
                accept(false)
                return
            }
            self.askToPair(name: name, deviceId: deviceId, publicKeySPKI: spki, accept: accept)
        }
        host.onStateChange = { [weak self] in self?.loadValues() }
    }

    /// Settings is closing: stop answering for the user. A pair request that
    /// arrives now is denied by the host rather than auto-accepted.
    func detach() {
        host.onPairRequest = nil
        host.onStateChange = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    // MARK: - Rows

    func rows(label: (String) -> NSTextField, caption: (String) -> NSTextField) -> [[NSView]] {
        relayField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return [
            [NSGridCell.emptyContentView, enableCheck],
            [NSGridCell.emptyContentView,
             caption("Off by default. Nothing leaves this Mac until you turn this on and pair a device.")],
            [label("Relay:"), relayField],
            // Security review C1: this used to say the relay "cannot read"
            // your traffic, full stop. That is true of the envelopes, and
            // false of whoever serves the browser page, which chooses the
            // JavaScript that encrypts for it. The page now comes from this
            // project's GitHub Pages site rather than the relay, so the
            // caption names the party that is actually trusted.
            //
            // Re-review N1: the caption no longer ASSERTS where the page
            // comes from — it used to state the default as fact while the
            // UI read nothing, so a `web_url` written into config.toml by
            // another process redirected every future pairing with the
            // Settings window still claiming GitHub. The line below states
            // the value actually in force.
            [NSGridCell.emptyContentView,
             caption("The relay forwards encrypted envelopes it can't read. Whoever serves the browser page "
                     + "can read and type for a browser device, so that origin — set by web_url — is who you "
                     + "trust.")],
            [NSGridCell.emptyContentView, pageLabel],
            [label("Status:"), statusLabel],
            [NSGridCell.emptyContentView, pairButton],
            [label("Devices:"), deviceScroll],
            [NSGridCell.emptyContentView,
             caption("Removing a device revokes it immediately, wherever it is.")],
        ]
    }

    private func buildDeviceTable() {
        deviceTable.dataSource = self
        deviceTable.delegate = self
        deviceTable.rowSizeStyle = .small
        deviceTable.usesAlternatingRowBackgroundColors = true
        deviceTable.headerView = NSTableHeaderView()
        for (identifier, title, width) in [("name", "Device", 180.0),
                                           ("seen", "Last seen", 110.0),
                                           ("remove", "", 80.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            deviceTable.addTableColumn(column)
        }
        deviceScroll.documentView = deviceTable
        deviceScroll.hasVerticalScroller = true
        deviceScroll.borderType = .bezelBorder
        deviceScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            deviceScroll.widthAnchor.constraint(equalToConstant: 380),
            deviceScroll.heightAnchor.constraint(equalToConstant: 96),
        ])
    }

    // MARK: - Values

    func loadValues() {
        let config = app.config
        enableCheck.state = config.remoteEnabled ? .on : .off
        relayField.stringValue = config.remoteRelayURL
        relayField.isEnabled = true
        pairButton.isEnabled = config.remoteEnabled
        statusLabel.stringValue = Self.statusText(state: host.probeState,
                                                  error: host.probeLastError,
                                                  hostId: config.remoteEnabled ? host.hostId : nil)
        pageLabel.stringValue = Self.pageText(relay: config.remoteRelayURL,
                                              webURL: config.remoteWebURL)
        devices = host.store.devices
        deviceTable.reloadData()
    }

    /// The "Pairing page:" line (security re-review N1), as its own function
    /// so the probe and tests can read it without an NSWindow.
    ///
    /// It states the origin a code would OPEN, derived the same way the QR
    /// is, rather than repeating what the config file says — a blank
    /// `web_url` means the relay serves the page, and that is what the user
    /// needs to see. When no usable origin exists, "Pair a device…" mints no
    /// code either, so the line says that instead of naming a default that
    /// is not in force.
    static func pageText(relay: String, webURL: String) -> String {
        guard let origin = RemotePairingPage.displayOrigin(relay: relay, webBase: webURL) else {
            return "Pairing page: unusable web_url — no pairing code can be shown"
        }
        return "Pairing page: \(origin)"
    }

    /// The status line, as its own function so the probe and tests can read
    /// it without an NSWindow.
    static func statusText(state: String, error: String?, hostId: String?) -> String {
        switch state {
        case "connected":
            return "Connected" + (hostId.map { " — this Mac is \($0)" } ?? "")
        case "connecting":
            return "Connecting…"
        case "offline":
            return "Offline — retrying" + (error.map { " (\($0))" } ?? "")
        default:
            // An error while off means the switch is on but something stopped
            // the host (an unusable relay URL, or an automated run).
            return "Off" + (error.map { " — \($0)" } ?? "")
        }
    }

    @objc private func controlChanged(_ sender: Any?) {
        var config = app.config
        config.remoteEnabled = enableCheck.state == .on
        let relay = relayField.stringValue.trimmingCharacters(in: .whitespaces)
        // A blank field means "the default", not "a URL that cannot be
        // parsed" — the same rule the config parser follows.
        if !relay.isEmpty { config.remoteRelayURL = relay }
        app.applyConfigLive(config)
        loadValues()
    }

    // MARK: - Pairing

    @objc private func pairAction(_ sender: Any?) {
        guard let window = pairButton.window else { return }
        // Mint first, register LAST: a token the user never sees a QR for
        // must not be live at the relay, so nothing is announced until the
        // image exists.
        let payload = host.makePairingPayload()
        guard let url = RemoteHost.pairingURL(for: payload, webBase: app.config.remoteWebURL),
              let image = Self.qrImage(for: url.absoluteString, side: 220)
        else { return }
        host.publishPairing(payload)
        pairingDeadline = Date(timeIntervalSince1970: Double(payload.expiresAt) / 1000)

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.widthAnchor.constraint(equalToConstant: 220).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let title = NSTextField(labelWithString: "Scan this with the device you want to pair")
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        // Re-review N1: the sheet used to show the image and nothing else,
        // so the one thing worth checking before scanning — which site the
        // code opens — was invisible at the moment it mattered.
        let caption = NSTextField(wrappingLabelWithString:
            "Your Mac will ask before the device is allowed in. The code works once.\n"
            + "It opens \(RemotePairingPage.displayOrigin(relay: payload.relay, webBase: app.config.remoteWebURL) ?? "")")
        caption.font = NSFont.systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 300
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countdownLabel.textColor = .secondaryLabelColor

        let done = NSButton(title: "Done", target: self, action: #selector(endPairingSheet))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, imageView, countdownLabel, caption, done])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 380),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = stack
        pairingSheet = sheet
        updateCountdown()
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateCountdown()
        }
        window.beginSheet(sheet) { [weak self] _ in
            self?.countdownTimer?.invalidate()
            self?.countdownTimer = nil
            self?.pairingSheet = nil
            // Final-review Important 3: every dismissal of this sheet (Done,
            // Cancel, or the window just closing) ends the pairing window,
            // so a token that is technically still live at the relay can no
            // longer reach the "Allow ?" prompt once nobody is looking at
            // the QR anymore.
            self?.host.endPairing()
        }
    }

    @objc private func endPairingSheet() {
        guard let sheet = pairingSheet else { return }
        sheet.sheetParent?.endSheet(sheet)
    }

    private func updateCountdown() {
        guard let deadline = pairingDeadline else { return }
        let remaining = Int(deadline.timeIntervalSinceNow.rounded())
        guard remaining > 0 else {
            countdownLabel.stringValue = "This code has expired"
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }
        countdownLabel.stringValue = String(format: "Expires in %d:%02d", remaining / 60, remaining % 60)
    }

    /// The consent step. The KEY is what gets stored; the name is only a
    /// label the device chose for itself, so it is shown in quotes and
    /// alongside the id the key hashes to.
    private func askToPair(name: String, deviceId: String, publicKeySPKI: Data,
                           accept: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Allow “\(name)” to attach?"
        alert.informativeText = """
            It will be able to see and type into these terminal sessions, \
            exactly as if it were sitting at this Mac. You can remove it at \
            any time in Settings ▸ Remote.

            Device key: \(deviceId)
            Check that this matches the key shown on the device. If it \
            doesn't, don't allow it.
            """
        // Deny is added FIRST, which makes it the default button: a stranger's
        // request must not be granted by a Return keystroke aimed at
        // something else.
        alert.addButton(withTitle: "Don't Allow")
        alert.addButton(withTitle: "Allow")
        let allowed = alert.runModal() == .alertSecondButtonReturn
        accept(allowed)
        if allowed { endPairingSheet() }
        loadValues()
    }

    /// The QR image for a pairing URL. `CIQRCodeGenerator` renders at one
    /// module per pixel, so it is scaled up with a nearest-neighbour-ish
    /// transform before it becomes an NSImage — a smoothed QR does not scan.
    static func qrImage(for string: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        // "M" recovers from ~15% damage, which is the right trade for a code
        // read off a screen at arm's length.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = side / max(output.extent.width, 1)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Device table

    func numberOfRows(in tableView: NSTableView) -> Int { devices.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard devices.indices.contains(row), let column = tableColumn else { return nil }
        let device = devices[row]
        switch column.identifier.rawValue {
        case "name":
            return Self.cell(device.name.isEmpty ? device.id : device.name)
        case "seen":
            return Self.cell(Self.lastSeenText(device.lastSeen))
        case "remove":
            let button = NSButton(title: "Remove", target: self, action: #selector(removeAction))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = row
            return button
        default:
            return nil
        }
    }

    private static func cell(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func lastSeenText(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    @objc private func removeAction(_ sender: NSButton) {
        guard devices.indices.contains(sender.tag) else { return }
        let device = devices[sender.tag]
        host.revoke(deviceId: device.id)
        loadValues()
    }

    // MARK: - Probe surface

    var probeStatusText: String { statusLabel.stringValue }
    var probeDeviceCount: Int { devices.count }
}
