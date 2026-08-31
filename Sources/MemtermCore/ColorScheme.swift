import Foundation

// Settings 2.0: built-in color-scheme presets. A preset is a one-gesture way
// to write ALL the theme keys — the TOML color keys stay the single source of
// truth (FR-44); `theme.preset` is only the display label, cleared the moment
// any color is edited by hand. AppKit-free so palettes are testable headlessly.

public struct ColorSchemePreset: Equatable {
    /// Stable id stored in `theme.preset` (kebab-case, filename-safe).
    public let id: String
    /// Human-readable popup title.
    public let name: String
    public let background: ConfigRGB
    public let foreground: ConfigRGB
    public let cursor: ConfigRGB
    public let selection: ConfigRGB
    /// Exactly 16 (normal 0–7, bright 8–15) — enforced by tests.
    public let ansi: [ConfigRGB]

    init(id: String, name: String, background: String, foreground: String,
         cursor: String, selection: String, ansi: [String]) {
        self.id = id
        self.name = name
        self.background = ConfigRGB(hex: background)!
        self.foreground = ConfigRGB(hex: foreground)!
        self.cursor = ConfigRGB(hex: cursor)!
        self.selection = ConfigRGB(hex: selection)!
        self.ansi = ansi.map { ConfigRGB(hex: $0)! }
    }
}

public enum ColorSchemes {

    /// "memterm Dark" is today's default palette (Tomorrow Night-derived,
    /// #1d1f21/#c5c8c6) shipped as a named preset — selecting it changes
    /// nothing for existing users.
    public static let presets: [ColorSchemePreset] = [
        ColorSchemePreset(
            id: "memterm-dark", name: "memterm Dark",
            background: "#1d1f21", foreground: "#c5c8c6",
            cursor: "#c5c8c6", selection: "#373b41",
            ansi: ["#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
                   "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                   "#969896", "#cc6666", "#b5bd68", "#f0c674",
                   "#81a2be", "#b294bb", "#8abeb7", "#ffffff"]),
        ColorSchemePreset(
            id: "solarized-dark", name: "Solarized Dark",
            background: "#002b36", foreground: "#839496",
            cursor: "#839496", selection: "#073642",
            ansi: ["#073642", "#dc322f", "#859900", "#b58900",
                   "#268bd2", "#d33682", "#2aa198", "#eee8d5",
                   "#002b36", "#cb4b16", "#586e75", "#657b83",
                   "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        ColorSchemePreset(
            id: "dracula", name: "Dracula",
            background: "#282a36", foreground: "#f8f8f2",
            cursor: "#f8f8f2", selection: "#44475a",
            ansi: ["#21222c", "#ff5555", "#50fa7b", "#f1fa8c",
                   "#bd93f9", "#ff79c6", "#8be9fd", "#f8f8f2",
                   "#6272a4", "#ff6e6e", "#69ff94", "#ffffa5",
                   "#d6acff", "#ff92df", "#a4ffff", "#ffffff"]),
        ColorSchemePreset(
            id: "gruvbox-dark", name: "Gruvbox Dark",
            background: "#282828", foreground: "#ebdbb2",
            cursor: "#ebdbb2", selection: "#504945",
            ansi: ["#282828", "#cc241d", "#98971a", "#d79921",
                   "#458588", "#b16286", "#689d6a", "#a89984",
                   "#928374", "#fb4934", "#b8bb26", "#fabd2f",
                   "#83a598", "#d3869b", "#8ec07c", "#ebdbb2"]),
        ColorSchemePreset(
            id: "nord", name: "Nord",
            background: "#2e3440", foreground: "#d8dee9",
            cursor: "#d8dee9", selection: "#434c5e",
            ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b",
                   "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0",
                   "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b",
                   "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        ColorSchemePreset(
            id: "one-light", name: "One Light",
            background: "#fafafa", foreground: "#383a42",
            cursor: "#383a42", selection: "#e5e5e6",
            ansi: ["#383a42", "#e45649", "#50a14f", "#c18401",
                   "#0184bc", "#a626a4", "#0997b3", "#fafafa",
                   "#4f525e", "#e06c75", "#98c379", "#e5c07b",
                   "#61afef", "#c678dd", "#56b6c2", "#ffffff"]),
    ]

    public static func preset(id: String) -> ColorSchemePreset? {
        presets.first { $0.id == id }
    }
}

extension Config {

    /// Writes every theme key from the preset and stamps `theme.preset`.
    public mutating func apply(preset: ColorSchemePreset) {
        themeBackground = preset.background
        themeForeground = preset.foreground
        themeCursor = preset.cursor
        themeSelection = preset.selection
        ansiColors = preset.ansi
        themePreset = preset.id
    }

    /// Writes every mapped theme key from an imported .itermcolors scheme.
    /// `presetLabel` (the filename stem) becomes the display label. Colors
    /// the file omits (cursor/selection are optional there) are cleared so a
    /// stale value from the previous theme never bleeds through.
    public mutating func apply(imported: ITermColors.Scheme, presetLabel: String) {
        themeBackground = imported.background
        themeForeground = imported.foreground
        themeCursor = imported.cursor
        themeSelection = imported.selection
        ansiColors = imported.ansi
        themePreset = presetLabel.isEmpty ? nil : presetLabel
    }
}
