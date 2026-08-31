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
    var terminalAnsiColors: [SwiftTerm.Color]? { ansiColors?.map(\.terminalColor) }
}
