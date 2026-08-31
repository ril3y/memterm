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
    public var scrollbackLines = 10_000
    public var shell: String?
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
        if case .int(let n)? = values["scrollback_lines"], n >= 0 { c.scrollbackLines = n }
        if let s = string(values["shell"]), !s.isEmpty { c.shell = s }

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

        # scrollback_lines = 10000

        # Default: $SHELL, run as a login shell.
        # shell = "/bin/zsh"

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
