import Foundation

// .itermcolors import (Settings 2.0 migration feature). Format verified
// against real schemes (iTerm2-Color-Schemes corpus) and iTerm2's docs:
// an Apple XML plist whose root dict keys "Ansi 0 Color"…"Ansi 15 Color",
// "Foreground Color", "Background Color" (required here) plus optional
// "Cursor Color" / "Selection Color" and others. Each value is a dict of
// <real> components "Red Component"/"Green Component"/"Blue Component" in
// 0.0–1.0; modern files add "Alpha Component" and "Color Space" (ignored —
// older files omit them and must still import). iTerm2 3.5+ may export
// mode-variant keys suffixed " (Light)"/" (Dark)": the unsuffixed set is
// preferred, the "(Dark)" set is the fallback. Everything else in the file
// (bold/link/badge/tab colors…) is deliberately dropped: memterm has no
// wells for them, and a silently-empty mapping beats a half-honored one.

public enum ITermColors {

    public struct Scheme: Equatable {
        public var background: ConfigRGB
        public var foreground: ConfigRGB
        public var cursor: ConfigRGB?
        public var selection: ConfigRGB?
        /// Exactly 16 — parse fails otherwise.
        public var ansi: [ConfigRGB]

        public init(background: ConfigRGB, foreground: ConfigRGB,
                    cursor: ConfigRGB?, selection: ConfigRGB?, ansi: [ConfigRGB]) {
            self.background = background
            self.foreground = foreground
            self.cursor = cursor
            self.selection = selection
            self.ansi = ansi
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        /// Not a property list at all, or its root is not a dictionary.
        case notAPropertyList
        /// A structurally valid plist missing required color entries.
        case missingColors([String])

        public var description: String {
            switch self {
            case .notAPropertyList:
                return "The file is not an iTerm2 color scheme (not a property list)."
            case .missingColors(let keys):
                return "The scheme is missing required colors: \(keys.joined(separator: ", "))."
            }
        }
    }

    public static func parse(_ data: Data) throws -> Scheme {
        guard let plist = try? PropertyListSerialization
                .propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any] else {
            throw ParseError.notAPropertyList
        }

        /// Unsuffixed key first, " (Dark)" variant as the 3.5+ fallback.
        func color(_ key: String) -> ConfigRGB? {
            rgb(root[key]) ?? rgb(root[key + " (Dark)"])
        }

        var missing: [String] = []
        var ansi: [ConfigRGB] = []
        for i in 0..<16 {
            if let c = color("Ansi \(i) Color") {
                ansi.append(c)
            } else {
                missing.append("Ansi \(i) Color")
            }
        }
        let background = color("Background Color")
        let foreground = color("Foreground Color")
        if background == nil { missing.append("Background Color") }
        if foreground == nil { missing.append("Foreground Color") }
        guard missing.isEmpty, let background, let foreground else {
            throw ParseError.missingColors(missing)
        }
        return Scheme(background: background,
                      foreground: foreground,
                      cursor: color("Cursor Color"),
                      selection: color("Selection Color"),
                      ansi: ansi)
    }

    /// One color dict → ConfigRGB. Components are read as any NSNumber (real
    /// in practice), clamped to [0,1]; Alpha and Color Space are ignored and
    /// never required (pre-3.x files lack both).
    private static func rgb(_ value: Any?) -> ConfigRGB? {
        guard let dict = value as? [String: Any] else { return nil }
        func component(_ key: String) -> Int? {
            guard let n = dict[key] as? NSNumber else { return nil }
            let clamped = min(max(n.doubleValue, 0.0), 1.0)
            return Int((clamped * 255).rounded())
        }
        guard let r = component("Red Component"),
              let g = component("Green Component"),
              let b = component("Blue Component") else { return nil }
        return ConfigRGB(red: r, green: g, blue: b)
    }
}
