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
}

public struct Config {
    public var fontFamily: String?
    public var fontSize: Double = 13
    public var copyOnSelect = true
    /// Founder UX: the always-visible workspace bar under the tab bar. Shown
    /// by default (the founder wants to SEE workspaces); `workspace_bar =
    /// false` hides it.
    public var workspaceBar = true
    public var scrollbackLines = 10_000
    public var shell: String?
    /// iTerm2 parity: ⌘T/⌘N (and the tab bar's "+") open in the key pane's
    /// current directory (kernel-truth cwd — works without shell integration).
    public var newTabSameCwd = true
    /// iTerm2 parity: Option sends Esc+ (meta) for readline/emacs word chords.
    /// SwiftTerm's default; `false` restores macOS special-character typing.
    public var optionAsMeta = true
    /// One of `bellStyles` (SwiftTerm BellStyle tagNames).
    public var bellStyle = "sound"
    /// One of `cursorStyles`, mapped onto SwiftTerm's six CursorStyle cases.
    public var cursorStyle = "blink-block"
    public var themeBackground: ConfigRGB?
    public var themeForeground: ConfigRGB?
    public var themeCursor: ConfigRGB?
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

    /// Valid `cursor_style` values, in the order Settings shows them.
    public static let cursorStyles = ["blink-block", "steady-block",
                                      "blink-underline", "steady-underline",
                                      "blink-bar", "steady-bar"]

    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
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
        if case .int(let n)? = values["scrollback_lines"], n >= 0 { c.scrollbackLines = n }
        if let s = string(values["shell"]), !s.isEmpty { c.shell = s }
        if let b = boolean(values["new_tab_same_cwd"]) { c.newTabSameCwd = b }
        if let b = boolean(values["option_as_meta"]) { c.optionAsMeta = b }
        // Unknown style values keep the defaults (never a broken terminal).
        if let s = string(values["bell_style"]), bellStyles.contains(s) { c.bellStyle = s }
        if let s = string(values["cursor_style"]), cursorStyles.contains(s) { c.cursorStyle = s }

        c.themeBackground = rgb(string(values["theme.background"]))
        c.themeForeground = rgb(string(values["theme.foreground"]))
        c.themeCursor = rgb(string(values["theme.cursor"]))

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
        guard let s else { return nil }
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return ConfigRGB(red: (v >> 16) & 0xff, green: (v >> 8) & 0xff, blue: v & 0xff)
    }

    // MARK: - Serialization (Settings UI writes through here; FR-44 keeps the
    // TOML file the on-disk source of truth)

    private static func hex(_ c: ConfigRGB) -> String {
        String(format: "#%02x%02x%02x", c.red, c.green, c.blue)
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
        lines.append("scrollback_lines = \(scrollbackLines)")
        if let shell {
            lines.append("shell = \"\(shell)\"")
        } else {
            lines.append("# shell = \"/bin/zsh\"  # default: $SHELL, run as a login shell")
        }
        lines.append("new_tab_same_cwd = \(newTabSameCwd)  # new tabs/windows open in the current directory")
        lines.append("option_as_meta = \(optionAsMeta)  # Option sends Esc+ (readline/emacs word keys)")
        lines.append("bell_style = \"\(bellStyle)\"  # \(Self.bellStyles.joined(separator: " | "))")
        lines.append("cursor_style = \"\(cursorStyle)\"  # \(Self.cursorStyles.joined(separator: " | "))")
        lines.append("")
        lines.append("[theme]")
        if let themeBackground { lines.append("background = \"\(Self.hex(themeBackground))\"") }
        if let themeForeground { lines.append("foreground = \"\(Self.hex(themeForeground))\"") }
        if let themeCursor { lines.append("cursor = \"\(Self.hex(themeCursor))\"") }
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

        # scrollback_lines = 10000

        # Default: $SHELL, run as a login shell.
        # shell = "/bin/zsh"

        # New tabs and windows open in the current pane's directory.
        # new_tab_same_cwd = true

        # Option sends Esc+ (meta) so Opt-B/Opt-F word movement works in the
        # shell. false makes Option type macOS special characters instead.
        # option_as_meta = true

        # What the terminal bell does: none | sound | visual | soundAndVisual.
        # bell_style = "sound"

        # Cursor: blink-block | steady-block | blink-underline |
        # steady-underline | blink-bar | steady-bar.
        # cursor_style = "blink-block"

        # [theme]
        # background = "#1d1f21"
        # foreground = "#c5c8c6"
        # cursor = "#c5c8c6"
        # ansi0 ... ansi15 override the 16 ANSI colors (all 16 required):
        # ansi0 = "#000000"
        """
        try? (defaults + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
