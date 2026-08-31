import AppKit
import MemtermCore
import SwiftTerm

// AppKit/SwiftTerm faces of the core Config: RGB triples become NSColor /
// terminal colors, and the pure font-name resolution becomes an NSFont.

extension ConfigRGB {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255, alpha: 1)
    }

    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
    }
}

extension Config {
    func resolveFont(size: CGFloat) -> NSFont {
        let name = Config.resolveFontName(preferred: fontFamily) {
            NSFont(name: $0, size: size) != nil
        }
        if let name, let font = NSFont(name: name, size: size) { return font }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var themeBackgroundColor: NSColor? { themeBackground?.nsColor }
    var themeForegroundColor: NSColor? { themeForeground?.nsColor }
    var themeCursorColor: NSColor? { themeCursor?.nsColor }
    var themeSelectionColor: NSColor? { themeSelection?.nsColor }
    var terminalAnsiColors: [SwiftTerm.Color]? { ansiColors?.map(\.terminalColor) }

    /// SwiftTerm's own selection default (MacTerminalView), pushed back when
    /// the theme's selection color is cleared.
    static let defaultSelectionColor = NSColor(srgbRed: 0, green: 166.0 / 255.0,
                                               blue: 178.0 / 255.0, alpha: 1.0)

    /// The 16 wells' seed when no theme palette is set — SwiftTerm's installed
    /// default palette (Color.defaultInstalledColors), so what the grid shows
    /// matches what panes render.
    static var defaultAnsiPalette: [ConfigRGB] {
        SwiftTerm.Color.defaultInstalledColors.map {
            ConfigRGB(red: Int($0.red >> 8), green: Int($0.green >> 8),
                      blue: Int($0.blue >> 8))
        }
    }

    /// `window_opacity`, clamped and quantized the way parse() stores it.
    var effectiveOpacity: CGFloat {
        CGFloat(min(max(windowOpacity, Config.windowOpacityRange.lowerBound),
                    Config.windowOpacityRange.upperBound))
    }

    var isWindowOpaque: Bool { effectiveOpacity >= 0.999 }

    /// `bell_style` — the config strings ARE BellStyle tagNames (verified in
    /// SwiftTerm's Apple/BellStyle.swift; parse() already validated them).
    var terminalBellStyle: BellStyle {
        BellStyle(tagName: bellStyle) ?? .sound
    }

    /// `cursor_style` — Config's kebab names onto SwiftTerm's CursorStyle
    /// (TerminalOptions.swift; setCursorStyle exists for live re-apply).
    var terminalCursorStyle: CursorStyle {
        switch cursorStyle {
        case "steady-block": return .steadyBlock
        case "blink-underline": return .blinkUnderline
        case "steady-underline": return .steadyUnderline
        case "blink-bar": return .blinkBar
        case "steady-bar": return .steadyBar
        default: return .blinkBlock
        }
    }
}
