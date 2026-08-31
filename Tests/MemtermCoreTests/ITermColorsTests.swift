import XCTest
@testable import MemtermCore

final class ITermColorsTests: XCTestCase {

    // MARK: - Fixture generation (the same shape iTerm2 exports)

    /// Builds a real .itermcolors XML plist. `modern` adds Color Space +
    /// Alpha Component (iTerm2 3.x); false mimics old exports that omit both.
    /// `suffix` produces 3.5-style mode-variant keys (e.g. " (Dark)").
    private func fixture(colors: [String: (Double, Double, Double)],
                         modern: Bool = true, suffix: String = "") -> Data {
        var entries = ""
        for (key, rgb) in colors.sorted(by: { $0.key < $1.key }) {
            entries += "\t<key>\(key)\(suffix)</key>\n\t<dict>\n"
            if modern {
                entries += "\t\t<key>Alpha Component</key>\n\t\t<real>1</real>\n"
                entries += "\t\t<key>Color Space</key>\n\t\t<string>sRGB</string>\n"
            }
            entries += "\t\t<key>Blue Component</key>\n\t\t<real>\(rgb.2)</real>\n"
            entries += "\t\t<key>Green Component</key>\n\t\t<real>\(rgb.1)</real>\n"
            entries += "\t\t<key>Red Component</key>\n\t\t<real>\(rgb.0)</real>\n"
            entries += "\t</dict>\n"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(entries)</dict>
        </plist>
        """
        return Data(xml.utf8)
    }

    /// A complete required set: 16 Ansi + Foreground + Background, with the
    /// optional Cursor and Selection entries.
    private func completeColors() -> [String: (Double, Double, Double)] {
        var colors: [String: (Double, Double, Double)] = [:]
        for i in 0..<16 {
            colors["Ansi \(i) Color"] = (Double(i) / 15.0, 0.5, 1.0 - Double(i) / 15.0)
        }
        colors["Background Color"] = (0.156862745, 0.164705882, 0.211764706)  // #282a36
        colors["Foreground Color"] = (0.972549020, 0.972549020, 0.949019608)  // #f8f8f2
        colors["Cursor Color"] = (1.0, 0.0, 0.5)
        colors["Selection Color"] = (0.266666667, 0.278431373, 0.352941176)   // #444758
        return colors
    }

    // MARK: - Tests

    func testParsesCompleteModernScheme() throws {
        let scheme = try ITermColors.parse(fixture(colors: completeColors()))
        XCTAssertEqual(scheme.background, ConfigRGB(red: 40, green: 42, blue: 54))
        XCTAssertEqual(scheme.foreground, ConfigRGB(red: 248, green: 248, blue: 242))
        XCTAssertEqual(scheme.cursor, ConfigRGB(red: 255, green: 0, blue: 128))
        XCTAssertEqual(scheme.selection, ConfigRGB(red: 68, green: 71, blue: 90))
        XCTAssertEqual(scheme.ansi.count, 16)
        XCTAssertEqual(scheme.ansi[0], ConfigRGB(red: 0, green: 128, blue: 255))
        XCTAssertEqual(scheme.ansi[15], ConfigRGB(red: 255, green: 128, blue: 0))
    }

    func testParsesLegacySchemeWithoutColorSpaceOrAlpha() throws {
        // Pre-3.x exports omit Color Space and Alpha — must still import.
        let scheme = try ITermColors.parse(fixture(colors: completeColors(), modern: false))
        XCTAssertEqual(scheme.background, ConfigRGB(red: 40, green: 42, blue: 54))
        XCTAssertEqual(scheme.ansi.count, 16)
    }

    func testOptionalCursorAndSelectionMayBeAbsent() throws {
        var colors = completeColors()
        colors["Cursor Color"] = nil
        colors["Selection Color"] = nil
        let scheme = try ITermColors.parse(fixture(colors: colors))
        XCTAssertNil(scheme.cursor)
        XCTAssertNil(scheme.selection)
    }

    func testDarkModeVariantKeysAreTheFallback() throws {
        // iTerm2 3.5+ export style: every key carries " (Dark)"/" (Light)"
        // suffixes and no unsuffixed set — the (Dark) set must be used.
        let scheme = try ITermColors.parse(
            fixture(colors: completeColors(), suffix: " (Dark)"))
        XCTAssertEqual(scheme.background, ConfigRGB(red: 40, green: 42, blue: 54))
        XCTAssertEqual(scheme.ansi.count, 16)
    }

    func testComponentsAreClampedToUnitRange() throws {
        var colors = completeColors()
        colors["Background Color"] = (1.5, -0.5, 0.5)
        let scheme = try ITermColors.parse(fixture(colors: colors))
        XCTAssertEqual(scheme.background, ConfigRGB(red: 255, green: 0, blue: 128))
    }

    func testMissingAnsiColorIsRejectedWithTheKeyNamed() {
        var colors = completeColors()
        colors["Ansi 7 Color"] = nil
        XCTAssertThrowsError(try ITermColors.parse(fixture(colors: colors))) { error in
            XCTAssertEqual(error as? ITermColors.ParseError,
                           .missingColors(["Ansi 7 Color"]))
        }
    }

    func testMissingForegroundAndBackgroundAreRejected() {
        var colors = completeColors()
        colors["Foreground Color"] = nil
        colors["Background Color"] = nil
        XCTAssertThrowsError(try ITermColors.parse(fixture(colors: colors))) { error in
            guard case .missingColors(let keys)? = error as? ITermColors.ParseError else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(keys.contains("Background Color"))
            XCTAssertTrue(keys.contains("Foreground Color"))
        }
    }

    func testGarbageDataIsNotAPropertyList() {
        XCTAssertThrowsError(try ITermColors.parse(Data("not a plist".utf8))) { error in
            XCTAssertEqual(error as? ITermColors.ParseError, .notAPropertyList)
        }
        // A valid plist whose root is an array is equally not a scheme.
        let arrayPlist = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><array/></plist>
        """.utf8)
        XCTAssertThrowsError(try ITermColors.parse(arrayPlist)) { error in
            XCTAssertEqual(error as? ITermColors.ParseError, .notAPropertyList)
        }
    }

    func testFixtureFileOnDiskRoundTrips() throws {
        // End-to-end through a real file, the way the NSOpenPanel path reads it.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-test-\(UUID().uuidString).itermcolors")
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture(colors: completeColors()).write(to: url)
        let scheme = try ITermColors.parse(Data(contentsOf: url))
        var config = Config()
        config.apply(imported: scheme, presetLabel: "memterm-test")
        let parsed = Config.parse(config.serialize())
        XCTAssertEqual(parsed.ansiColors, scheme.ansi)
        XCTAssertEqual(parsed.themePreset, "memterm-test")
    }
}
