import AppKit
import MemtermCore

// FR-44/48: the real settings UI — one page, no preference-pane sprawl.
// Every control applies live to open terminals AND writes back to the TOML
// (Config.save), which stays the on-disk source of truth. Scrollback and
// shell can only affect panes created after the change; the captions say so.

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private unowned let app: MemtermAppDelegate

    private let fontPopUp = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let copyOnSelectCheck = NSButton(checkboxWithTitle: "Selecting text copies it", target: nil, action: nil)
    private let sameCwdCheck = NSButton(checkboxWithTitle: "New tabs open in the current directory", target: nil, action: nil)
    private let optionMetaCheck = NSButton(checkboxWithTitle: "Option key sends Esc+ (meta)", target: nil, action: nil)
    private let alwaysTabBarCheck = NSButton(checkboxWithTitle: "Always show the tab bar", target: nil, action: nil)
    private let bellPopUp = NSPopUpButton()
    private let cursorPopUp = NSPopUpButton()
    private let scrollbackField = NSTextField()
    private let shellField = NSTextField()
    private let bgWell = NSColorWell()
    private let fgWell = NSColorWell()
    private let cursorWell = NSColorWell()

    init(app: MemtermAppDelegate) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildForm()
        loadValues()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Form

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func buildForm() {
        fontPopUp.target = self
        fontPopUp.action = #selector(controlChanged)
        sizeField.target = self
        sizeField.action = #selector(controlChanged)
        sizeField.alignment = .right
        sizeStepper.minValue = 6
        sizeStepper.maxValue = 72
        sizeStepper.increment = 1
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped)
        copyOnSelectCheck.target = self
        copyOnSelectCheck.action = #selector(controlChanged)
        sameCwdCheck.target = self
        sameCwdCheck.action = #selector(controlChanged)
        optionMetaCheck.target = self
        optionMetaCheck.action = #selector(controlChanged)
        alwaysTabBarCheck.target = self
        alwaysTabBarCheck.action = #selector(controlChanged)
        // Popup rows mirror Config's valid-value lists index-for-index.
        bellPopUp.addItems(withTitles: ["None", "Sound", "Visual", "Sound and Visual"])
        bellPopUp.target = self
        bellPopUp.action = #selector(controlChanged)
        cursorPopUp.addItems(withTitles: ["Blinking Block", "Steady Block",
                                          "Blinking Underline", "Steady Underline",
                                          "Blinking Bar", "Steady Bar"])
        cursorPopUp.target = self
        cursorPopUp.action = #selector(controlChanged)
        let scrollbackFormatter = NumberFormatter()
        scrollbackFormatter.minimum = 100
        scrollbackFormatter.maximum = 200_000
        scrollbackFormatter.allowsFloats = false
        scrollbackField.formatter = scrollbackFormatter
        scrollbackField.target = self
        scrollbackField.action = #selector(controlChanged)
        shellField.placeholderString = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        shellField.target = self
        shellField.action = #selector(controlChanged)
        for well in [bgWell, fgWell, cursorWell] {
            well.target = self
            well.action = #selector(controlChanged)
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }

        let sizeRow = NSStackView(views: [sizeField, sizeStepper])
        sizeRow.orientation = .horizontal
        sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let colorRow = NSStackView(views: [
            bgWell, caption("Background"), fgWell, caption("Text"), cursorWell, caption("Cursor"),
        ])
        colorRow.orientation = .horizontal
        colorRow.spacing = 6

        let resetColors = NSButton(title: "Use Default Colors", target: self,
                                   action: #selector(resetColorsAction))
        resetColors.bezelStyle = .rounded
        resetColors.controlSize = .small
        let editFile = NSButton(title: "Edit Config File…", target: self,
                                action: #selector(editFileAction))
        editFile.bezelStyle = .rounded
        editFile.controlSize = .small
        let fileRow = NSStackView(views: [resetColors, editFile])
        fileRow.orientation = .horizontal

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Font:"), fontPopUp],
            [NSTextField(labelWithString: "Size:"), sizeRow],
            [NSGridCell.emptyContentView, copyOnSelectCheck],
            [NSGridCell.emptyContentView, sameCwdCheck],
            [NSGridCell.emptyContentView, optionMetaCheck],
            [NSGridCell.emptyContentView, alwaysTabBarCheck],
            [NSTextField(labelWithString: "Cursor:"), cursorPopUp],
            [NSTextField(labelWithString: "Bell:"), bellPopUp],
            [NSTextField(labelWithString: "Scrollback:"), scrollbackField],
            [NSGridCell.emptyContentView, caption("Lines kept and restored. Applies to new panes.")],
            [NSTextField(labelWithString: "Shell:"), shellField],
            [NSGridCell.emptyContentView, caption("Applies to new panes. Blank uses $SHELL.")],
            [NSTextField(labelWithString: "Colors:"), colorRow],
            [NSGridCell.emptyContentView, caption("The 16 ANSI colors are editable in the config file.")],
            [NSGridCell.emptyContentView, fileRow],
        ])
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
        window?.setContentSize(NSSize(width: 460, height: 380))
    }

    /// Monospaced families installed on this machine, with the configured
    /// family kept selectable even if it vanished, plus an "Automatic" row
    /// for the nerd-font-first default chain.
    private func loadValues() {
        let config = app.config
        fontPopUp.removeAllItems()
        fontPopUp.addItem(withTitle: "Automatic (nerd font)")
        var families: [String] = []
        for family in NSFontManager.shared.availableFontFamilies {
            if let font = NSFont(name: family, size: 12), font.isFixedPitch {
                families.append(family)
            }
        }
        if let configured = config.fontFamily, !families.contains(configured) {
            families.insert(configured, at: 0)
        }
        fontPopUp.addItems(withTitles: families)
        if let configured = config.fontFamily {
            fontPopUp.selectItem(withTitle: configured)
        } else {
            fontPopUp.selectItem(at: 0)
        }
        sizeField.stringValue = String(Int(config.fontSize))
        sizeStepper.integerValue = Int(config.fontSize)
        copyOnSelectCheck.state = config.copyOnSelect ? .on : .off
        sameCwdCheck.state = config.newTabSameCwd ? .on : .off
        optionMetaCheck.state = config.optionAsMeta ? .on : .off
        alwaysTabBarCheck.state = config.alwaysShowTabBar ? .on : .off
        bellPopUp.selectItem(at: Config.bellStyles.firstIndex(of: config.bellStyle) ?? 1)
        cursorPopUp.selectItem(at: Config.cursorStyles.firstIndex(of: config.cursorStyle) ?? 0)
        scrollbackField.integerValue = config.scrollbackLines
        shellField.stringValue = config.shell ?? ""
        bgWell.color = config.themeBackgroundColor ?? .black
        fgWell.color = config.themeForegroundColor ?? NSColor(srgbRed: 0.77, green: 0.78, blue: 0.78, alpha: 1)
        cursorWell.color = config.themeCursorColor ?? fgWell.color
    }

    // MARK: - Apply

    private func rgb(_ color: NSColor) -> ConfigRGB? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return ConfigRGB(red: Int(round(c.redComponent * 255)),
                         green: Int(round(c.greenComponent * 255)),
                         blue: Int(round(c.blueComponent * 255)))
    }

    private var themeCleared = false

    @objc private func sizeStepped(_ sender: NSStepper) {
        sizeField.stringValue = String(sender.integerValue)
        controlChanged(sender)
    }

    @objc private func controlChanged(_ sender: Any?) {
        var config = app.config
        config.fontFamily = fontPopUp.indexOfSelectedItem == 0 ? nil : fontPopUp.titleOfSelectedItem
        if let size = Double(sizeField.stringValue), size >= 6, size <= 72 {
            config.fontSize = size
            sizeStepper.integerValue = Int(size)
        }
        config.copyOnSelect = copyOnSelectCheck.state == .on
        config.newTabSameCwd = sameCwdCheck.state == .on
        config.optionAsMeta = optionMetaCheck.state == .on
        config.alwaysShowTabBar = alwaysTabBarCheck.state == .on
        if Config.bellStyles.indices.contains(bellPopUp.indexOfSelectedItem) {
            config.bellStyle = Config.bellStyles[bellPopUp.indexOfSelectedItem]
        }
        if Config.cursorStyles.indices.contains(cursorPopUp.indexOfSelectedItem) {
            config.cursorStyle = Config.cursorStyles[cursorPopUp.indexOfSelectedItem]
        }
        if scrollbackField.integerValue >= 100 { config.scrollbackLines = scrollbackField.integerValue }
        let shell = shellField.stringValue.trimmingCharacters(in: .whitespaces)
        config.shell = shell.isEmpty ? nil : shell
        if themeCleared {
            config.themeBackground = nil
            config.themeForeground = nil
            config.themeCursor = nil
        } else {
            config.themeBackground = rgb(bgWell.color)
            config.themeForeground = rgb(fgWell.color)
            config.themeCursor = rgb(cursorWell.color)
        }
        // A color well changing means the user picked colors again.
        if sender as? NSColorWell != nil { themeCleared = false; config.themeBackground = rgb(bgWell.color); config.themeForeground = rgb(fgWell.color); config.themeCursor = rgb(cursorWell.color) }
        app.applyConfigLive(config)
    }

    @objc private func resetColorsAction(_ sender: Any?) {
        themeCleared = true
        var config = app.config
        config.themeBackground = nil
        config.themeForeground = nil
        config.themeCursor = nil
        app.applyConfigLive(config)
        loadValues()
    }

    @objc private func editFileAction(_ sender: Any?) {
        NSWorkspace.shared.open(Config.configURL)
    }

    func show() {
        loadValues()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.close()
    }
}
