import AppKit
import MemtermCore
import UniformTypeIdentifiers

// FR-44/48: the real settings UI — Settings 2.0. Four small native sections
// (General / Appearance / Terminal / Memory) in an NSTabView; a handful of
// clean sections is fine, a preference palace is failure (product doctrine:
// no iTerm2-style 10-tab sprawl — see the stage's refuse list). Every
// control applies live to open terminals AND writes back to the TOML
// (Config.save), which stays the on-disk source of truth. Scrollback and
// shell can only affect panes created after the change; the captions say so.

final class SettingsWindowController: NSWindowController, NSWindowDelegate,
                                      NSTabViewDelegate {
    private unowned let app: MemtermAppDelegate
    private let tabView = NSTabView()

    // General
    private let sameCwdCheck = NSButton(checkboxWithTitle: "New tabs open in the current directory", target: nil, action: nil)
    private let copyOnSelectCheck = NSButton(checkboxWithTitle: "Selecting text copies it", target: nil, action: nil)
    private let confirmQuitCheck = NSButton(checkboxWithTitle: "Confirm quitting while jobs are running", target: nil, action: nil)
    private let workspaceBarCheck = NSButton(checkboxWithTitle: "Show the workspace bar", target: nil, action: nil)
    private let shellField = NSTextField()

    // Appearance
    private let fontPopUp = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let lineSpacingSlider = NSSlider()
    private let lineSpacingLabel = NSTextField(labelWithString: "1.0")
    private let schemePopUp = NSPopUpButton()
    private let bgWell = NSColorWell()
    private let fgWell = NSColorWell()
    private let cursorWell = NSColorWell()
    private let selectionWell = NSColorWell()
    private var ansiWells: [NSColorWell] = (0..<16).map { _ in NSColorWell() }
    private let opacitySlider = NSSlider()
    private let opacityLabel = NSTextField(labelWithString: "")
    private let blurCheck = NSButton(checkboxWithTitle: "Blur what's behind the window", target: nil, action: nil)

    // Terminal
    private let cursorPopUp = NSPopUpButton()
    private let bellPopUp = NSPopUpButton()
    private let bellSoundPopUp = NSPopUpButton()
    private let optionMetaCheck = NSButton(checkboxWithTitle: "Option key sends Esc+ (meta)", target: nil, action: nil)
    private let mouseReportingCheck = NSButton(checkboxWithTitle: "Allow apps to use the mouse (vim, htop)", target: nil, action: nil)
    private let shellIntegrationCheck = NSButton(checkboxWithTitle: "Shell integration (zsh)", target: nil, action: nil)
    // feature/serial: defaults for NEW serial connections (per-device
    // profiles override once a device has been connected).
    private let serialLineEndingPopUp = NSPopUpButton()
    private let serialEchoCheck = NSButton(checkboxWithTitle: "Local echo in serial panes", target: nil, action: nil)

    // Memory
    private let scrollbackField = NSTextField()
    private let diskUsageLabel = NSTextField(labelWithString: "Calculating…")

    /// True while the theme keys are deliberately unset ("Use Default
    /// Colors") so unrelated control changes don't bake the wells' default
    /// colors into the file. Any well edit turns colors back on.
    private var themeCleared = false
    /// The 16-well grid writes all-or-nothing (the palette invariant): only
    /// once the config has a palette — or a well was touched — do changes
    /// serialize ansi0…15.
    private var ansiActive = false
    /// Suppresses controlChanged side effects while loadValues() sets state.
    private var isLoading = false

    init(app: MemtermAppDelegate) {
        self.app = app
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildForm()
        loadValues()
        sizeToFitSection(animate: false)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Form

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 360
        return label
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func wire(_ control: NSControl) {
        control.target = self
        control.action = #selector(controlChanged)
    }

    private func makeTab(_ title: String, rows: [[NSView]]) -> NSTabViewItem {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
        ])
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = content
        return item
    }

    private func buildForm() {
        for check in [sameCwdCheck, copyOnSelectCheck, confirmQuitCheck, workspaceBarCheck,
                      optionMetaCheck, mouseReportingCheck, blurCheck,
                      shellIntegrationCheck] {
            wire(check)
        }
        wire(fontPopUp)
        wire(sizeField)
        sizeField.alignment = .right
        sizeStepper.minValue = 6
        sizeStepper.maxValue = 72
        sizeStepper.increment = 1
        sizeStepper.target = self
        sizeStepper.action = #selector(sizeStepped)

        lineSpacingSlider.minValue = Config.lineSpacingRange.lowerBound
        lineSpacingSlider.maxValue = Config.lineSpacingRange.upperBound
        lineSpacingSlider.numberOfTickMarks = 13  // 0.05 steps over 1.0–1.6
        lineSpacingSlider.allowsTickMarkValuesOnly = true
        wire(lineSpacingSlider)

        schemePopUp.target = self
        schemePopUp.action = #selector(schemeChanged)
        let importButton = NSButton(title: "Import iTerm2 Colors…", target: self,
                                    action: #selector(importSchemeAction))
        importButton.bezelStyle = .rounded
        importButton.controlSize = .small

        for well in [bgWell, fgWell, cursorWell, selectionWell] {
            wire(well)
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        for well in ansiWells {
            wire(well)
            well.widthAnchor.constraint(equalToConstant: 30).isActive = true
            well.heightAnchor.constraint(equalToConstant: 20).isActive = true
        }

        opacitySlider.minValue = Config.windowOpacityRange.lowerBound
        opacitySlider.maxValue = Config.windowOpacityRange.upperBound
        wire(opacitySlider)

        // Popup rows mirror Config's valid-value lists index-for-index.
        bellPopUp.addItems(withTitles: ["None", "Sound", "Visual", "Sound and Visual"])
        wire(bellPopUp)
        bellSoundPopUp.addItems(withTitles: ["System Beep"] + Config.bellSounds)
        bellSoundPopUp.target = self
        bellSoundPopUp.action = #selector(bellSoundChanged)
        cursorPopUp.addItems(withTitles: ["Blinking Block", "Steady Block",
                                          "Blinking Underline", "Steady Underline",
                                          "Blinking Bar", "Steady Bar"])
        wire(cursorPopUp)
        serialLineEndingPopUp.addItems(withTitles: SerialLineEnding.labels)
        wire(serialLineEndingPopUp)
        wire(serialEchoCheck)

        let scrollbackFormatter = NumberFormatter()
        scrollbackFormatter.minimum = 100
        scrollbackFormatter.maximum = 200_000
        scrollbackFormatter.allowsFloats = false
        scrollbackField.formatter = scrollbackFormatter
        wire(scrollbackField)
        shellField.placeholderString = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        wire(shellField)

        // -- General --
        let editFile = NSButton(title: "Edit Config File…", target: self,
                                action: #selector(editFileAction))
        editFile.bezelStyle = .rounded
        editFile.controlSize = .small
        let general = makeTab("General", rows: [
            [NSGridCell.emptyContentView, sameCwdCheck],
            [NSGridCell.emptyContentView, copyOnSelectCheck],
            [NSGridCell.emptyContentView, confirmQuitCheck],
            [NSGridCell.emptyContentView, caption("⌘Q asks only while foreground jobs are running. Quitting always remembers your layout and sessions.")],
            [NSGridCell.emptyContentView, workspaceBarCheck],
            [label("Shell:"), shellField],
            [NSGridCell.emptyContentView, caption("Applies to new panes. Blank uses $SHELL.")],
            [NSGridCell.emptyContentView, editFile],
        ])
        shellField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        // -- Appearance --
        let sizeRow = NSStackView(views: [sizeField, sizeStepper])
        sizeRow.orientation = .horizontal
        sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true

        let spacingRow = NSStackView(views: [lineSpacingSlider, lineSpacingLabel])
        spacingRow.orientation = .horizontal
        lineSpacingSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        lineSpacingLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        let schemeRow = NSStackView(views: [schemePopUp, importButton])
        schemeRow.orientation = .horizontal

        let colorRow = NSStackView(views: [
            bgWell, caption("Background"), fgWell, caption("Text"),
            cursorWell, caption("Cursor"), selectionWell, caption("Selection"),
        ])
        colorRow.orientation = .horizontal
        colorRow.spacing = 6

        let ansiGrid = NSGridView(views: [
            [label("Normal")] + ansiWells[0..<8].map { $0 as NSView },
            [label("Bright")] + ansiWells[8..<16].map { $0 as NSView },
        ])
        ansiGrid.rowSpacing = 4
        ansiGrid.columnSpacing = 4
        for row in 0..<2 {
            (ansiGrid.cell(atColumnIndex: 0, rowIndex: row).contentView as? NSTextField)?
                .font = NSFont.systemFont(ofSize: 10)
        }

        // Council #11: a LIVE readout — the slider says what it is set to,
        // not just its endpoints ("Opaque" at 100%, "NN%" below).
        let opacityRow = NSStackView(views: [caption("30%"), opacitySlider, opacityLabel])
        opacityRow.orientation = .horizontal
        opacitySlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        opacityLabel.textColor = .secondaryLabelColor
        opacityLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        let resetColors = NSButton(title: "Use Default Colors", target: self,
                                   action: #selector(resetColorsAction))
        resetColors.bezelStyle = .rounded
        resetColors.controlSize = .small

        let appearance = makeTab("Appearance", rows: [
            [label("Font:"), fontPopUp],
            [label("Size:"), sizeRow],
            [label("Line spacing:"), spacingRow],
            [label("Scheme:"), schemeRow],
            [label("Colors:"), colorRow],
            [label("ANSI colors:"), ansiGrid],
            [NSGridCell.emptyContentView, caption("Editing any color switches the scheme to Custom.")],
            [label("Transparency:"), opacityRow],
            [NSGridCell.emptyContentView, blurCheck],
            [NSGridCell.emptyContentView, caption("Background only — text stays opaque. Blur may reduce scrolling smoothness.")],
            [NSGridCell.emptyContentView, resetColors],
        ])

        // -- Terminal --
        let terminal = makeTab("Terminal", rows: [
            [label("Cursor:"), cursorPopUp],
            [label("Bell:"), bellPopUp],
            [label("Bell sound:"), bellSoundPopUp],
            [NSGridCell.emptyContentView, optionMetaCheck],
            [NSGridCell.emptyContentView, mouseReportingCheck],
            [NSGridCell.emptyContentView, caption("Off forces native text selection everywhere; apps stop seeing the mouse.")],
            [NSGridCell.emptyContentView, shellIntegrationCheck],
            [NSGridCell.emptyContentView, caption("Per-tab ↑ history, prompt marks, and directory tracking, injected at spawn — no dotfile edits. Applies to new panes; zsh only for now.")],
            [label("Serial line ending:"), serialLineEndingPopUp],
            [NSGridCell.emptyContentView, serialEchoCheck],
            [NSGridCell.emptyContentView, caption("Defaults for Shell ▸ New Serial Connection. Each device remembers what you last used with it.")],
        ])

        // -- Memory --
        let reveal = NSButton(title: "Reveal in Finder", target: self,
                              action: #selector(revealMemoryAction))
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        let usageRow = NSStackView(views: [diskUsageLabel, reveal])
        usageRow.orientation = .horizontal
        diskUsageLabel.font = NSFont.systemFont(ofSize: 12)
        diskUsageLabel.textColor = .secondaryLabelColor
        // Council #5: a deep state-dir path truncates in the MIDDLE (the
        // interesting parts are the ends) instead of stretching the window;
        // the tooltip carries the full path.
        diskUsageLabel.lineBreakMode = .byTruncatingMiddle
        diskUsageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        diskUsageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330).isActive = true

        let forget = NSButton(title: "Forget Everything…", target: self,
                              action: #selector(forgetEverythingAction))
        forget.bezelStyle = .rounded
        forget.hasDestructiveAction = true

        let memory = makeTab("Memory", rows: [
            [label("Scrollback:"), scrollbackField],
            [NSGridCell.emptyContentView, caption("Lines kept and restored. Applies to new panes.")],
            [label("On disk:"), usageRow],
            [NSGridCell.emptyContentView, caption("Layouts, scrollback history, and session records — all local, never uploaded.")],
            [NSGridCell.emptyContentView, NSBox.separator()],
            [NSGridCell.emptyContentView, forget],
            [NSGridCell.emptyContentView, caption("Deletes all memory including scrollback files on disk. Open terminals stay open.")],
        ])
        scrollbackField.widthAnchor.constraint(equalToConstant: 90).isActive = true

        tabView.addTabViewItem(general)
        tabView.addTabViewItem(appearance)
        tabView.addTabViewItem(terminal)
        tabView.addTabViewItem(memory)
        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window?.contentView = content
        window?.setContentSize(NSSize(width: 560, height: 480))
    }

    // MARK: - Per-section sizing (council #5)

    /// Native Settings behavior: the window is as tall as the SELECTED
    /// section needs — never stuck at the tallest section's height, top edge
    /// pinned across switches. Width stays fixed (560): nothing may stretch
    /// it, which is what keeps a deep state-dir path truncating instead.
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        sizeToFitSection(animate: true)
    }

    private func sizeToFitSection(animate: Bool) {
        guard let window, let view = tabView.selectedTabViewItem?.view else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        // Constant chrome around the section: tab control + outer margins.
        let chrome = (window.contentView?.frame.height ?? 0) - tabView.contentRect.height
        let target = NSRect(x: 0, y: 0, width: 560,
                            height: view.fittingSize.height + chrome)
        var frame = window.frameRect(forContentRect: target)
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height  // keep the top edge
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }

    // MARK: - Probe accessors (MEMTERM_UI_PROBE, council #5 gate)

    func probeSelectSection(_ label: String) {
        guard let item = tabView.tabViewItems.first(where: { $0.label == label })
        else { return }
        tabView.selectTabViewItem(item)
    }

    var probeContentSize: NSSize {
        window.map { $0.contentRect(forFrameRect: $0.frame).size } ?? .zero
    }

    var probeDiskUsageTruncatesMiddle: Bool {
        diskUsageLabel.lineBreakMode == .byTruncatingMiddle
    }

    var probeOpacityReadout: String { opacityLabel.stringValue }

    // MARK: - Load

    /// Monospaced families installed on this machine, with the configured
    /// family kept selectable even if it vanished, plus an "Automatic" row
    /// for the nerd-font-first default chain.
    private func loadValues() {
        isLoading = true
        defer { isLoading = false }
        let config = app.config

        // General
        sameCwdCheck.state = config.newTabSameCwd ? .on : .off
        copyOnSelectCheck.state = config.copyOnSelect ? .on : .off
        confirmQuitCheck.state = config.confirmQuit ? .on : .off
        workspaceBarCheck.state = config.workspaceBar ? .on : .off
        shellField.stringValue = config.shell ?? ""

        // Appearance
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
        lineSpacingSlider.doubleValue = config.lineSpacing
        lineSpacingLabel.stringValue = String(format: "%.2f×", config.lineSpacing)
        reloadSchemePopUp(config)
        themeCleared = config.themeBackground == nil && config.themeForeground == nil
            && config.themeCursor == nil && config.themeSelection == nil
        ansiActive = config.ansiColors != nil
        bgWell.color = config.themeBackgroundColor ?? .black
        fgWell.color = config.themeForegroundColor
            ?? NSColor(srgbRed: 0.77, green: 0.78, blue: 0.78, alpha: 1)
        cursorWell.color = config.themeCursorColor ?? fgWell.color
        selectionWell.color = config.themeSelectionColor ?? Config.defaultSelectionColor
        let palette = config.ansiColors ?? Config.defaultAnsiPalette
        for (well, color) in zip(ansiWells, palette) { well.color = color.nsColor }
        opacitySlider.doubleValue = config.windowOpacity
        updateOpacityReadout(config.windowOpacity)
        blurCheck.state = config.windowBlur ? .on : .off
        blurCheck.isEnabled = !config.isWindowOpaque

        // Terminal
        cursorPopUp.selectItem(at: Config.cursorStyles.firstIndex(of: config.cursorStyle) ?? 0)
        bellPopUp.selectItem(at: Config.bellStyles.firstIndex(of: config.bellStyle) ?? 1)
        if let sound = config.bellSound, let index = Config.bellSounds.firstIndex(of: sound) {
            bellSoundPopUp.selectItem(at: index + 1)  // 0 = System Beep
        } else {
            bellSoundPopUp.selectItem(at: 0)
        }
        bellSoundPopUp.isEnabled = config.bellStyle == "sound"
            || config.bellStyle == "soundAndVisual"
        optionMetaCheck.state = config.optionAsMeta ? .on : .off
        mouseReportingCheck.state = config.allowMouseReporting ? .on : .off
        shellIntegrationCheck.state = config.shellIntegration ? .on : .off
        serialLineEndingPopUp.selectItem(
            at: Config.serialLineEndings.firstIndex(of: config.serialTxLineEnding) ?? 2)
        serialEchoCheck.state = config.serialLocalEcho ? .on : .off

        // Memory
        scrollbackField.integerValue = config.scrollbackLines
    }

    /// Preset names + (a non-builtin import label when present) + Custom.
    private func reloadSchemePopUp(_ config: Config) {
        schemePopUp.removeAllItems()
        for preset in ColorSchemes.presets { schemePopUp.addItem(withTitle: preset.name) }
        var selectIndex: Int?
        if let id = config.themePreset {
            if let index = ColorSchemes.presets.firstIndex(where: { $0.id == id }) {
                selectIndex = index
            } else {
                schemePopUp.addItem(withTitle: id)  // imported scheme's label
                selectIndex = schemePopUp.numberOfItems - 1
            }
        }
        schemePopUp.menu?.addItem(.separator())
        schemePopUp.addItem(withTitle: "Custom")
        schemePopUp.selectItem(at: selectIndex ?? schemePopUp.numberOfItems - 1)
    }

    // MARK: - Apply

    private func rgb(_ color: NSColor) -> ConfigRGB? {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        return ConfigRGB(red: Int(round(c.redComponent * 255)),
                         green: Int(round(c.greenComponent * 255)),
                         blue: Int(round(c.blueComponent * 255)))
    }

    /// Council #11: live "%" readout beside the transparency slider —
    /// "Opaque" at 100 keeps the old endpoint's honesty.
    private func updateOpacityReadout(_ opacity: Double) {
        let pct = Int((opacity * 100).rounded())
        opacityLabel.stringValue = pct >= 100 ? "Opaque" : "\(pct)%"
    }

    @objc private func sizeStepped(_ sender: NSStepper) {
        sizeField.stringValue = String(sender.integerValue)
        controlChanged(sender)
    }

    @objc private func controlChanged(_ sender: Any?) {
        guard !isLoading else { return }
        var config = app.config

        // General
        config.newTabSameCwd = sameCwdCheck.state == .on
        config.copyOnSelect = copyOnSelectCheck.state == .on
        config.confirmQuit = confirmQuitCheck.state == .on
        config.workspaceBar = workspaceBarCheck.state == .on
        let shell = shellField.stringValue.trimmingCharacters(in: .whitespaces)
        config.shell = shell.isEmpty ? nil : shell

        // Appearance
        config.fontFamily = fontPopUp.indexOfSelectedItem == 0 ? nil : fontPopUp.titleOfSelectedItem
        if let size = Double(sizeField.stringValue), size >= 6, size <= 72 {
            config.fontSize = size
            sizeStepper.integerValue = Int(size)
        }
        config.lineSpacing = (lineSpacingSlider.doubleValue * 100).rounded() / 100
        lineSpacingLabel.stringValue = String(format: "%.2f×", config.lineSpacing)
        config.windowOpacity = (opacitySlider.doubleValue * 100).rounded() / 100
        updateOpacityReadout(config.windowOpacity)
        config.windowBlur = blurCheck.state == .on
        blurCheck.isEnabled = !config.isWindowOpaque

        // A color well changing means the user picked colors again — and any
        // hand edit turns the scheme label into "Custom" (the preset is only
        // a derived label; the color keys are the truth).
        if let well = sender as? NSColorWell {
            themeCleared = false
            if config.themePreset != nil {
                config.themePreset = nil
                reloadSchemePopUp(config)
            }
            if ansiWells.contains(well) { ansiActive = true }
        }
        if themeCleared {
            config.themeBackground = nil
            config.themeForeground = nil
            config.themeCursor = nil
            config.themeSelection = nil
        } else {
            config.themeBackground = rgb(bgWell.color)
            config.themeForeground = rgb(fgWell.color)
            config.themeCursor = rgb(cursorWell.color)
            config.themeSelection = rgb(selectionWell.color)
        }
        // All-16 invariant: the grid always writes the full set.
        config.ansiColors = ansiActive ? ansiWells.compactMap { rgb($0.color) } : nil

        // Terminal
        if Config.cursorStyles.indices.contains(cursorPopUp.indexOfSelectedItem) {
            config.cursorStyle = Config.cursorStyles[cursorPopUp.indexOfSelectedItem]
        }
        if Config.bellStyles.indices.contains(bellPopUp.indexOfSelectedItem) {
            config.bellStyle = Config.bellStyles[bellPopUp.indexOfSelectedItem]
        }
        let soundIndex = bellSoundPopUp.indexOfSelectedItem
        config.bellSound = soundIndex > 0 && Config.bellSounds.indices.contains(soundIndex - 1)
            ? Config.bellSounds[soundIndex - 1] : nil
        bellSoundPopUp.isEnabled = config.bellStyle == "sound"
            || config.bellStyle == "soundAndVisual"
        config.optionAsMeta = optionMetaCheck.state == .on
        config.allowMouseReporting = mouseReportingCheck.state == .on
        config.shellIntegration = shellIntegrationCheck.state == .on
        if Config.serialLineEndings.indices.contains(serialLineEndingPopUp.indexOfSelectedItem) {
            config.serialTxLineEnding = Config.serialLineEndings[serialLineEndingPopUp.indexOfSelectedItem]
        }
        config.serialLocalEcho = serialEchoCheck.state == .on

        // Memory
        if scrollbackField.integerValue >= 100 { config.scrollbackLines = scrollbackField.integerValue }

        app.applyConfigLive(config)
    }

    @objc private func bellSoundChanged(_ sender: Any?) {
        controlChanged(sender)
        // Preview the pick so choosing a sound doesn't require triggering a bell.
        if let sound = app.config.bellSound { NSSound(named: sound)?.play() }
    }

    /// Selecting a preset writes ALL color keys plus the derived label;
    /// "Custom" (and the transient import label) are display-only rows.
    @objc private func schemeChanged(_ sender: Any?) {
        guard !isLoading,
              ColorSchemes.presets.indices.contains(schemePopUp.indexOfSelectedItem)
        else { return }
        var config = app.config
        config.apply(preset: ColorSchemes.presets[schemePopUp.indexOfSelectedItem])
        app.applyConfigLive(config)
        loadValues()
    }

    /// Killer migration feature: parse a real .itermcolors (MemtermCore.
    /// ITermColors), map Ansi 0–15 + fg/bg/cursor/selection into the theme
    /// keys, apply live. Malformed or incomplete files get a clear alert.
    @objc private func importSchemeAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "itermcolors") {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scheme = try ITermColors.parse(Data(contentsOf: url))
            var config = app.config
            config.apply(imported: scheme,
                         presetLabel: url.deletingPathExtension().lastPathComponent)
            app.applyConfigLive(config)
            loadValues()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't import “\(url.lastPathComponent)”"
            alert.informativeText = (error as? ITermColors.ParseError)?.description
                ?? error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func resetColorsAction(_ sender: Any?) {
        themeCleared = true
        ansiActive = false
        var config = app.config
        config.themeBackground = nil
        config.themeForeground = nil
        config.themeCursor = nil
        config.themeSelection = nil
        config.ansiColors = nil
        config.themePreset = nil
        app.applyConfigLive(config)
        loadValues()
    }

    @objc private func editFileAction(_ sender: Any?) {
        NSWorkspace.shared.open(Config.configURL)
    }

    // MARK: - Memory section

    @objc private func revealMemoryAction(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([MemoryEngine.baseDir])
    }

    @objc private func forgetEverythingAction(_ sender: Any?) {
        app.forgetEverythingAction(sender)
        refreshDiskUsage()
    }

    /// FR-45: the on-disk location, surfaced with its size. Computed with a
    /// background walk (honors MEMTERM_STATE_DIR), never on the input path.
    private func refreshDiskUsage() {
        let dir = MemoryEngine.baseDir
        diskUsageLabel.stringValue = "Calculating…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var total: Int64 = 0
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey]
            if let walker = FileManager.default.enumerator(at: dir,
                                                           includingPropertiesForKeys: Array(keys)) {
                for case let url as URL in walker {
                    let values = try? url.resourceValues(forKeys: keys)
                    total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                }
            }
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let path = (dir.path as NSString).abbreviatingWithTildeInPath
            DispatchQueue.main.async {
                self?.diskUsageLabel.stringValue = "\(size) · \(path)"
                self?.diskUsageLabel.toolTip = dir.path  // full path on hover
            }
        }
    }

    // MARK: - Show / close

    func show() {
        loadValues()
        refreshDiskUsage()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSColorPanel.shared.close()
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 320).isActive = true
        return box
    }
}
