import XCTest
@testable import MemtermCore

final class ColorSchemeTests: XCTestCase {

    func testEveryPresetIsComplete() {
        XCTAssertFalse(ColorSchemes.presets.isEmpty)
        for preset in ColorSchemes.presets {
            XCTAssertEqual(preset.ansi.count, 16, "\(preset.id) must carry all 16 ANSI colors")
            XCTAssertFalse(preset.id.isEmpty)
            XCTAssertFalse(preset.name.isEmpty)
        }
    }

    func testPresetIdsAreUniqueAndLookupWorks() {
        let ids = ColorSchemes.presets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "preset ids must be unique")
        for preset in ColorSchemes.presets {
            XCTAssertEqual(ColorSchemes.preset(id: preset.id), preset)
        }
        XCTAssertNil(ColorSchemes.preset(id: "no-such-scheme"))
    }

    func testMemtermDarkMatchesTodaysDefault() {
        // Shipping the default as a named preset must change nothing for
        // existing users: it IS the documented #1d1f21/#c5c8c6 palette.
        let preset = ColorSchemes.preset(id: "memterm-dark")
        XCTAssertEqual(preset?.background, ConfigRGB(hex: "#1d1f21"))
        XCTAssertEqual(preset?.foreground, ConfigRGB(hex: "#c5c8c6"))
        XCTAssertEqual(ColorSchemes.presets.first?.id, "memterm-dark",
                       "the default preset leads the popup")
    }

    func testApplyPresetWritesAllThemeKeysAndRoundTrips() {
        var config = Config()
        let dracula = ColorSchemes.preset(id: "dracula")!
        config.apply(preset: dracula)
        XCTAssertEqual(config.themeBackground, dracula.background)
        XCTAssertEqual(config.themeForeground, dracula.foreground)
        XCTAssertEqual(config.themeCursor, dracula.cursor)
        XCTAssertEqual(config.themeSelection, dracula.selection)
        XCTAssertEqual(config.ansiColors, dracula.ansi)
        XCTAssertEqual(config.themePreset, "dracula")

        // FR-44: the file, not the preset name, is the truth — and it
        // round-trips losslessly.
        let parsed = Config.parse(config.serialize())
        XCTAssertEqual(parsed.ansiColors, dracula.ansi)
        XCTAssertEqual(parsed.themePreset, "dracula")
        XCTAssertEqual(parsed.themeSelection, dracula.selection)
    }

    func testApplyImportedSchemeClearsOmittedOptionalColors() {
        var config = Config()
        config.apply(preset: ColorSchemes.preset(id: "nord")!)
        let scheme = ITermColors.Scheme(
            background: ConfigRGB(hex: "#101010")!,
            foreground: ConfigRGB(hex: "#e0e0e0")!,
            cursor: nil, selection: nil,
            ansi: (0..<16).map { ConfigRGB(red: $0, green: $0, blue: $0) })
        config.apply(imported: scheme, presetLabel: "MyScheme")
        XCTAssertEqual(config.themeBackground, ConfigRGB(hex: "#101010"))
        XCTAssertNil(config.themeCursor, "a stale cursor color must not bleed through")
        XCTAssertNil(config.themeSelection)
        XCTAssertEqual(config.themePreset, "MyScheme")
    }

    func testConfigRGBHexRoundTrip() {
        XCTAssertEqual(ConfigRGB(hex: "#8abeb7"),
                       ConfigRGB(red: 0x8a, green: 0xbe, blue: 0xb7))
        XCTAssertEqual(ConfigRGB(hex: "8abeb7"), ConfigRGB(hex: "#8abeb7"))
        XCTAssertNil(ConfigRGB(hex: "#8abeb"))
        XCTAssertNil(ConfigRGB(hex: "#zzzzzz"))
        XCTAssertEqual(ConfigRGB(hex: "#8abeb7")?.hexString, "#8abeb7")
    }
}
