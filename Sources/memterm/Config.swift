import AppKit
import SwiftTerm

// FR-44: one human-editable TOML file as the source of truth. The parser below
// is a deliberate subset (key = value, [section] headers, quoted strings, ints,
// floats, bools, # comments) — no package dependency for a config file.

enum TomlValue {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

func parseTomlSubset(_ text: String) -> [String: TomlValue] {
    var result: [String: TomlValue] = [:]
    var section = ""
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("[") && line.hasSuffix("]") {
            section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            continue
        }
        guard let eq = line.firstIndex(of: "=") else { continue }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { continue }
        let fullKey = section.isEmpty ? key : "\(section).\(key)"
        result[fullKey] = parseTomlValue(value)
    }
    return result
}

/// Removes a trailing `# comment`, respecting `#` inside quoted strings.
private func stripComment(_ line: String) -> String {
    var inString = false
    var escaped = false
    for (i, ch) in line.enumerated() {
        if escaped { escaped = false; continue }
        switch ch {
        case "\\" where inString: escaped = true
        case "\"": inString.toggle()
        case "#" where !inString:
            return String(line.prefix(i))
        default: break
        }
    }
    return line
}

private func parseTomlValue(_ raw: String) -> TomlValue {
    if raw.hasPrefix("\"") {
        var out = ""
        var escaped = false
        for ch in raw.dropFirst() {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                break
            } else {
                out.append(ch)
            }
        }
        return .string(out)
    }
    if raw == "true" { return .bool(true) }
    if raw == "false" { return .bool(false) }
    if let i = Int(raw) { return .int(i) }
    if let d = Double(raw) { return .double(d) }
    return .string(raw)
}

struct Config {
    var fontFamily: String?
    var fontSize: CGFloat = 13
    var copyOnSelect = true
    var scrollbackLines = 10_000
    var shell: String?
    var themeBackground: NSColor?
    var themeForeground: NSColor?
    var themeCursor: NSColor?
    var ansiColors: [SwiftTerm.Color]?  // exactly 16 when present

    // Nerd-font-first default chain: the founder's powerline prompt renders "?"
    // boxes without one of these. SFMono-Regular is SF Mono's PostScript name.
    static let fontCandidates = [
        "MesloLGS NF", "MesloLGS Nerd Font",
        "JetBrainsMono Nerd Font Mono", "JetBrainsMono Nerd Font",
        "Hack Nerd Font Mono", "FiraCode Nerd Font Mono",
        "SF Mono", "SFMono-Regular", "Menlo",
    ]

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/memterm/config.toml")
    }

    func resolveFont(size: CGFloat) -> NSFont {
        if let family = fontFamily, let f = NSFont(name: family, size: size) { return f }
        for name in Config.fontCandidates {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func load() -> Config {
        createDefaultFileIfMissing()
        var c = Config()
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return c }
        let values = parseTomlSubset(text)

        if let s = string(values["font_family"]), !s.isEmpty { c.fontFamily = s }
        if let n = number(values["font_size"]), n > 4 { c.fontSize = CGFloat(n) }
        if let b = boolean(values["copy_on_select"]) { c.copyOnSelect = b }
        if case .int(let n)? = values["scrollback_lines"], n >= 0 { c.scrollbackLines = n }
        if let s = string(values["shell"]), !s.isEmpty { c.shell = s }

        c.themeBackground = nsColor(string(values["theme.background"]))
        c.themeForeground = nsColor(string(values["theme.foreground"]))
        c.themeCursor = nsColor(string(values["theme.cursor"]))

        var ansi: [SwiftTerm.Color] = []
        for i in 0..<16 {
            guard let hex = string(values["theme.ansi\(i)"]), let (r, g, b) = parseHexColor(hex) else {
                ansi = []
                break
            }
            ansi.append(SwiftTerm.Color(red8: UInt16(r), green8: UInt16(g), blue8: UInt16(b)))
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

    private static func parseHexColor(_ s: String) -> (Int, Int, Int)? {
        var hex = s.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return nil }
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }

    private static func nsColor(_ hex: String?) -> NSColor? {
        guard let hex, let (r, g, b) = parseHexColor(hex) else { return nil }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: 1)
    }

    private static func createDefaultFileIfMissing() {
        let url = configURL
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
