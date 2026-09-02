import Foundation

// Config model + parsing, AppKit-free so it is testable headlessly. Colors are
// plain RGB triples here; the executable maps them to NSColor / SwiftTerm
// colors, and resolves font *names* chosen by `resolveFontName` into NSFonts.

public struct ConfigRGB: Equatable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rrggbb` (leading `#` optional). The single hex parser for config
    /// values, presets, and scheme imports.
    public init?(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        self.init(red: (v >> 16) & 0xff, green: (v >> 8) & 0xff, blue: v & 0xff)
    }

    public var hexString: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }
}

public struct Config {
    public var fontFamily: String?
    public var fontSize: Double = 13
    public var copyOnSelect = true
    /// Founder UX: the always-visible workspace bar under the tab bar. Shown
    /// by default (the founder wants to SEE workspaces); `workspace_bar =
    /// false` hides it.
    public var workspaceBar = true
    /// DEPRECATED NO-OP (custom-tab-chrome stage 2): memterm's own tab strip
    /// is the window's titlebar surface and is always visible — collapsing it
    /// would orphan titles, rename, drag, and activity. The key stays parsed
    /// (and written back) so existing config files round-trip without noise.
    public var alwaysShowTabBar = true
    public var scrollbackLines = 10_000
    /// Founder-amended FR-56 retention: archived sessions (closed tabs'
    /// frozen scrollback + history) older than this many days are deleted at
    /// launch. 0 keeps the archive forever. Age-based rather than a size cap:
    /// "how far back can I search" is the promise users can reason about.
    public var archiveRetentionDays = 90
    public var shell: String?
    /// FR-5 / per-tab history: spawn zsh panes through the ZDOTDIR wrapper
    /// (per-tab ↑ history, OSC 7 cwd, OSC 133 prompt marks). `false` spawns
    /// shells exactly as before the feature existed. zsh only this stage;
    /// other shells always spawn plain.
    public var shellIntegration = true
    /// iTerm2 parity: ⌘T/⌘N (and the tab bar's "+") open in the key pane's
    /// current directory (kernel-truth cwd — works without shell integration).
    public var newTabSameCwd = true
    /// iTerm2 parity: Option sends Esc+ (meta) for readline/emacs word chords.
    /// SwiftTerm's default; `false` restores macOS special-character typing.
    public var optionAsMeta = true
    /// One of `bellStyles` (SwiftTerm BellStyle tagNames).
    public var bellStyle = "sound"
    /// A named macOS sound from `bellSounds`, or nil for the system beep.
    /// Only heard when `bellStyle` includes sound.
    public var bellSound: String?
    /// One of `cursorStyles`, mapped onto SwiftTerm's six CursorStyle cases.
    public var cursorStyle = "blink-block"
    /// Founder confirm-quit stage: ⌘Q with running foreground jobs asks first
    /// (plain shells quit instantly either way — FR-20 stays lossless).
    public var confirmQuit = true
    /// Vertical line-spacing multiplier (SwiftTerm's lineSpacing), 1.0–1.6.
    public var lineSpacing = 1.0
    /// Terminal mouse reporting (vim/htop capture the mouse). SwiftTerm's
    /// allowMouseReporting; false forces native selection everywhere.
    public var allowMouseReporting = true
    /// feature/serial: what Enter transmits in NEW serial panes — one of
    /// `serialLineEndings` (per-pane override in the connect sheet; per-device
    /// profiles remember the last choice). CRLF is the research consensus
    /// default for Arduino/ESP-class monitors.
    public var serialTxLineEnding = "crlf"
    /// feature/serial: local echo default for NEW serial panes (most firmware
    /// echoes for itself, so off by default).
    public var serialLocalEcho = false
    /// Window background opacity, 0.3–1.0 (1.0 = opaque). Applied as
    /// background-color alpha, never window alpha — text stays crisp.
    public var windowOpacity = 1.0
    /// Behind-window blur (NSVisualEffectView). Only meaningful when
    /// `windowOpacity` < 1.
    public var windowBlur = false
    public var themeBackground: ConfigRGB?
    public var themeForeground: ConfigRGB?
    public var themeCursor: ConfigRGB?
    /// Selection highlight (SwiftTerm selectedTextBackgroundColor).
    public var themeSelection: ConfigRGB?
    /// Display label for the preset/import the theme keys came from. Derived,
    /// never authoritative (FR-44: the color keys are the source of truth);
    /// cleared whenever a color is edited by hand.
    public var themePreset: String?
    public var ansiColors: [ConfigRGB]?  // exactly 16 when present

    public init() {}

    // Nerd-font-first default chain: the founder's powerline prompt renders "?"
    // boxes without one of these. SFMono-Regular is SF Mono's PostScript name.
    public static let fontCandidates = [
        "MesloLGS NF", "MesloLGS Nerd Font",
        "JetBrainsMono Nerd Font Mono", "JetBrainsMono Nerd Font",
        "Hack Nerd Font Mono", "FiraCode Nerd Font Mono",
        "SF Mono", "SFMono-Regular", "Menlo",
    ]

    /// Valid `bell_style` values — SwiftTerm's BellStyle tagNames verbatim.
    public static let bellStyles = ["none", "sound", "visual", "soundAndVisual"]

    /// Valid `bell_sound` values — the classic named macOS system sounds
    /// (present in /System/Library/Sounds on every supported macOS).
    public static let bellSounds = ["Basso", "Blow", "Bottle", "Frog", "Funk",
                                    "Glass", "Hero", "Morse", "Ping", "Pop",
                                    "Purr", "Sosumi", "Submarine", "Tink"]

    /// `line_spacing` bounds (SwiftTerm honors any multiplier; beyond 1.6 the
    /// grid falls apart visually).
    public static let lineSpacingRange = 1.0...1.6
    /// `window_opacity` bounds (below 30% the terminal stops being readable).
    public static let windowOpacityRange = 0.3...1.0

    /// Valid `cursor_style` values, in the order Settings shows them.
    public static let cursorStyles = ["blink-block", "steady-block",
                                      "blink-underline", "steady-underline",
                                      "blink-bar", "steady-bar"]

    /// Valid `serial_tx_line_ending` values (SerialLineEnding raw values).
    public static let serialLineEndings = SerialLineEnding.configValues

    /// MEMTERM_CONFIG_PATH overrides the config location, parallel to
    /// MEMTERM_STATE_DIR (TESTING.md §2.2): probe/smoke runs and the verify
    /// config matrix point this at generated files so gate coverage never
    /// silently depends on — or writes into — the runner's ~/.config/memterm.
    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["MEMTERM_CONFIG_PATH"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/memterm/config.toml")
    }

    /// The configured family if installed, else the first installed candidate,
    /// else nil (caller falls back to the system monospaced font).
    public static func resolveFontName(preferred: String?,
                                       isAvailable: (String) -> Bool) -> String? {
        if let preferred, !preferred.isEmpty, isAvailable(preferred) { return preferred }
        return fontCandidates.first(where: isAvailable)
    }

    public static func load(from url: URL = configURL) -> Config {
        createDefaultFileIfMissing(at: url)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return Config() }
        return parse(text)
    }

    public static func parse(_ text: String) -> Config {
        var c = Config()
        let values = parseTomlSubset(text)

        if let s = string(values["font_family"]), !s.isEmpty { c.fontFamily = s }
        if let n = number(values["font_size"]), n > 4 { c.fontSize = n }
        if let b = boolean(values["copy_on_select"]) { c.copyOnSelect = b }
        if let b = boolean(values["workspace_bar"]) { c.workspaceBar = b }
        if let b = boolean(values["always_show_tab_bar"]) { c.alwaysShowTabBar = b }
        if case .int(let n)? = values["scrollback_lines"], n >= 0 { c.scrollbackLines = n }
        if case .int(let n)? = values["archive_retention_days"], n >= 0 { c.archiveRetentionDays = n }
        if let s = string(values["shell"]), !s.isEmpty { c.shell = s }
        if let b = boolean(values["shell_integration"]) { c.shellIntegration = b }
        if let b = boolean(values["new_tab_same_cwd"]) { c.newTabSameCwd = b }
        if let b = boolean(values["option_as_meta"]) { c.optionAsMeta = b }
        // Unknown style values keep the defaults (never a broken terminal).
        if let s = string(values["bell_style"]), bellStyles.contains(s) { c.bellStyle = s }
        if let s = string(values["bell_sound"]), bellSounds.contains(s) { c.bellSound = s }
        if let s = string(values["cursor_style"]), cursorStyles.contains(s) { c.cursorStyle = s }
        if let s = string(values["serial_tx_line_ending"]), serialLineEndings.contains(s) {
            c.serialTxLineEnding = s
        }
        if let b = boolean(values["serial_local_echo"]) { c.serialLocalEcho = b }
        if let b = boolean(values["confirm_quit"]) { c.confirmQuit = b }
        if let b = boolean(values["allow_mouse_reporting"]) { c.allowMouseReporting = b }
        if let b = boolean(values["window_blur"]) { c.windowBlur = b }
        // Numeric knobs clamp into their sane range (a hand-typed 3.0 line
        // spacing yields the max, never a broken grid), rounded to the 2
        // decimals the serializer writes so round trips are exact.
        if let n = number(values["line_spacing"]) {
            c.lineSpacing = (min(max(n, lineSpacingRange.lowerBound),
                                 lineSpacingRange.upperBound) * 100).rounded() / 100
        }
        if let n = number(values["window_opacity"]) {
            c.windowOpacity = (min(max(n, windowOpacityRange.lowerBound),
                                   windowOpacityRange.upperBound) * 100).rounded() / 100
        }

        c.themeBackground = rgb(string(values["theme.background"]))
        c.themeForeground = rgb(string(values["theme.foreground"]))
        c.themeCursor = rgb(string(values["theme.cursor"]))
        c.themeSelection = rgb(string(values["theme.selection"]))
        if let s = string(values["theme.preset"]), !s.isEmpty { c.themePreset = s }

        var ansi: [ConfigRGB] = []
        for i in 0..<16 {
            guard let hex = string(values["theme.ansi\(i)"]), let color = rgb(hex) else {
                ansi = []
                break
            }
            ansi.append(color)
        }
        if ansi.count == 16 { c.ansiColors = ansi }
        return c
    }

    private static func string(_ v: TomlValue?) -> String? {
        if case .string(let s)? = v { return s }
        return nil
    }

    private static func number(_ v: TomlValue?) -> Double? {
        switch v {
        case .int(let n)?: return Double(n)
        case .double(let d)?: return d
        default: return nil
        }
    }

    private static func boolean(_ v: TomlValue?) -> Bool? {
        if case .bool(let b)? = v { return b }
        return nil
    }

    private static func rgb(_ s: String?) -> ConfigRGB? {
        s.flatMap { ConfigRGB(hex: $0) }
    }

    // MARK: - Serialization (Settings UI writes through here; FR-44 keeps the
    // TOML file the on-disk source of truth)

    private static func hex(_ c: ConfigRGB) -> String {
        c.hexString
    }

    private static func twoDecimals(_ n: Double) -> String {
        let rounded = (n * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(format: "%.1f", rounded) : String(format: "%.2f", rounded)
    }

    /// Regenerates the config file body from the current values. Unset
    /// optionals stay as commented guidance so the file remains self-teaching.
    public func serialize() -> String {
        var lines: [String] = [
            "# memterm configuration — edited by Settings (⌘,) and by hand.",
            "",
        ]
        if let fontFamily {
            lines.append("font_family = \"\(fontFamily)\"")
        } else {
            lines.append("# font_family = \"MesloLGS NF\"  # default: first installed nerd font")
        }
        lines.append("font_size = \(fontSize == fontSize.rounded() ? String(Int(fontSize)) : String(fontSize))")
        lines.append("copy_on_select = \(copyOnSelect)")
        lines.append("workspace_bar = \(workspaceBar)")
        lines.append("always_show_tab_bar = \(alwaysShowTabBar)  # no-op: memterm's tab strip is always visible")
        lines.append("scrollback_lines = \(scrollbackLines)")
        lines.append("archive_retention_days = \(archiveRetentionDays)  # closed-tab archive kept this long; 0 = forever")
        if let shell {
            lines.append("shell = \"\(shell)\"")
        } else {
            lines.append("# shell = \"/bin/zsh\"  # default: $SHELL, run as a login shell")
        }
        lines.append("shell_integration = \(shellIntegration)  # per-tab ↑ history + prompt marks (zsh)")
        lines.append("new_tab_same_cwd = \(newTabSameCwd)  # new tabs/windows open in the current directory")
        lines.append("option_as_meta = \(optionAsMeta)  # Option sends Esc+ (readline/emacs word keys)")
        lines.append("confirm_quit = \(confirmQuit)  # ⌘Q asks first when foreground jobs are running")
        lines.append("allow_mouse_reporting = \(allowMouseReporting)  # apps (vim, htop) may capture the mouse")
        lines.append("bell_style = \"\(bellStyle)\"  # \(Self.bellStyles.joined(separator: " | "))")
        if let bellSound {
            lines.append("bell_sound = \"\(bellSound)\"  # macOS sound name; unset = system beep")
        } else {
            lines.append("# bell_sound = \"Glass\"  # \(Self.bellSounds.joined(separator: " | ")); unset = system beep")
        }
        lines.append("cursor_style = \"\(cursorStyle)\"  # \(Self.cursorStyles.joined(separator: " | "))")
        lines.append("serial_tx_line_ending = \"\(serialTxLineEnding)\"  # \(Self.serialLineEndings.joined(separator: " | ")) — Enter in serial panes")
        lines.append("serial_local_echo = \(serialLocalEcho)  # echo typed bytes locally in serial panes")
        lines.append("line_spacing = \(Self.twoDecimals(lineSpacing))  # 1.0–1.6 line-height multiplier")
        lines.append("window_opacity = \(Self.twoDecimals(windowOpacity))  # 0.3–1.0 background opacity (1.0 = opaque)")
        lines.append("window_blur = \(windowBlur)  # blur what's behind a translucent window")
        lines.append("")
        lines.append("[theme]")
        if let themePreset { lines.append("preset = \"\(themePreset)\"  # display label; colors below are the truth") }
        if let themeBackground { lines.append("background = \"\(Self.hex(themeBackground))\"") }
        if let themeForeground { lines.append("foreground = \"\(Self.hex(themeForeground))\"") }
        if let themeCursor { lines.append("cursor = \"\(Self.hex(themeCursor))\"") }
        if let themeSelection { lines.append("selection = \"\(Self.hex(themeSelection))\"") }
        if let ansiColors, ansiColors.count == 16 {
            for (i, c) in ansiColors.enumerated() { lines.append("ansi\(i) = \"\(Self.hex(c))\"") }
        } else {
            lines.append("# ansi0 ... ansi15 override the 16 ANSI colors (all 16 required)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func save(to url: URL = configURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? serialize().write(to: url, atomically: true, encoding: .utf8)
    }

    public static func createDefaultFileIfMissing(at url: URL = configURL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let defaults = """
        # memterm configuration — applied at launch. ⌘, opens this file.

        # Font. Default: first installed of MesloLGS NF / JetBrainsMono Nerd Font /
        # Hack Nerd Font / FiraCode Nerd Font / SF Mono / Menlo.
        # font_family = "MesloLGS NF"
        # font_size = 13

        # Selecting text copies it to the clipboard immediately.
        # copy_on_select = true

        # The workspace bar (chips under the tab bar). false hides it.
        # workspace_bar = true

        # No-op (kept for old config files): memterm draws its own tab strip
        # and it is always visible.
        # always_show_tab_bar = true

        # scrollback_lines = 10000
        # archive_retention_days = 90   # closed-tab archive kept this long; 0 = forever

        # Default: $SHELL, run as a login shell.
        # shell = "/bin/zsh"

        # Shell integration (zsh): per-tab ↑ history, prompt marks, and
        # directory tracking, injected at spawn — no dotfile edits. false
        # spawns shells exactly as a plain terminal would.
        # shell_integration = true

        # New tabs and windows open in the current pane's directory.
        # new_tab_same_cwd = true

        # Option sends Esc+ (meta) so Opt-B/Opt-F word movement works in the
        # shell. false makes Option type macOS special characters instead.
        # option_as_meta = true

        # ⌘Q asks first when foreground jobs are still running. Plain shells
        # quit instantly either way (quit always keeps your layout/sessions).
        # confirm_quit = true

        # Let terminal apps (vim, htop) capture the mouse. false keeps native
        # text selection everywhere.
        # allow_mouse_reporting = true

        # What the terminal bell does: none | sound | visual | soundAndVisual.
        # bell_style = "sound"
        # bell_sound = "Glass"  # named macOS sound; unset = system beep

        # Cursor: blink-block | steady-block | blink-underline |
        # steady-underline | blink-bar | steady-bar.
        # cursor_style = "blink-block"

        # Serial panes (Shell > New Serial Connection): what Enter transmits
        # (cr | lf | crlf | none) and whether typed bytes echo locally.
        # serial_tx_line_ending = "crlf"
        # serial_local_echo = false

        # Line-height multiplier, 1.0–1.6.
        # line_spacing = 1.0

        # Window background opacity 0.3–1.0 (text stays opaque), plus optional
        # behind-window blur while translucent.
        # window_opacity = 1.0
        # window_blur = false

        # [theme]
        # preset = "memterm-dark"  # display label set by Settings; colors win
        # background = "#1d1f21"
        # foreground = "#c5c8c6"
        # cursor = "#c5c8c6"
        # selection = "#373b41"
        # ansi0 ... ansi15 override the 16 ANSI colors (all 16 required):
        # ansi0 = "#000000"
        """
        try? (defaults + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
