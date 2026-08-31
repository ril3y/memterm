import XCTest
@testable import MemtermCore

final class ConfigTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Defaults file

    func testLoadCreatesAndParsesDefaultsFile() {
        let url = tempDir.appendingPathComponent("config.toml")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let c = Config.load(from: url)
        // The generated file exists and, being all comments, yields pure defaults.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(c.fontFamily)
        XCTAssertEqual(c.fontSize, 13)
        XCTAssertTrue(c.copyOnSelect)
        XCTAssertEqual(c.scrollbackLines, 10_000)
        XCTAssertNil(c.shell)
        XCTAssertNil(c.themeBackground)
        XCTAssertNil(c.ansiColors)
    }

    func testLoadParsesRealValuesFromDisk() throws {
        let url = tempDir.appendingPathComponent("config.toml")
        try """
        font_family = "MesloLGS NF"
        font_size = 15
        copy_on_select = false
        scrollback_lines = 500
        shell = "/bin/bash"

        [theme]
        background = "#1d1f21"
        """.write(to: url, atomically: true, encoding: .utf8)
        let c = Config.load(from: url)
        XCTAssertEqual(c.fontFamily, "MesloLGS NF")
        XCTAssertEqual(c.fontSize, 15)
        XCTAssertFalse(c.copyOnSelect)
        XCTAssertEqual(c.scrollbackLines, 500)
        XCTAssertEqual(c.shell, "/bin/bash")
        XCTAssertEqual(c.themeBackground, ConfigRGB(red: 0x1d, green: 0x1f, blue: 0x21))
    }

    // MARK: TOML subset parser

    func testQuotedStringsEscapesAndInlineComments() {
        let values = parseTomlSubset("""
        a = "with # hash inside"   # trailing comment
        b = "tab\\there \\"quoted\\" and\\nnewline"
        c = "escaped backslash before quote \\\\" # comment
        d = 42 # int with comment
        """)
        XCTAssertEqual(values["a"], .string("with # hash inside"))
        XCTAssertEqual(values["b"], .string("tab\there \"quoted\" and\nnewline"))
        XCTAssertEqual(values["c"], .string("escaped backslash before quote \\"))
        XCTAssertEqual(values["d"], .int(42))
    }

    func testSectionsPrefixKeys() {
        let values = parseTomlSubset("""
        top = 1
        [theme]
        background = "#000000"
        [ spaced ]
        key = true
        """)
        XCTAssertEqual(values["top"], .int(1))
        XCTAssertEqual(values["theme.background"], .string("#000000"))
        XCTAssertEqual(values["spaced.key"], .bool(true))
    }

    func testValueTypes() {
        let values = parseTomlSubset("""
        i = 7
        f = 3.5
        t = true
        x = false
        bare = hello-bare-word
        """)
        XCTAssertEqual(values["i"], .int(7))
        XCTAssertEqual(values["f"], .double(3.5))
        XCTAssertEqual(values["t"], .bool(true))
        XCTAssertEqual(values["x"], .bool(false))
        XCTAssertEqual(values["bare"], .string("hello-bare-word"))
    }

    func testBadLinesAreIgnoredGracefully() {
        let values = parseTomlSubset("""
        this line is garbage
        = value-without-key
        key-without-value =
        [unclosed-section
        good = 1
        """)
        // Only the well-formed line survives; nothing throws.
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values["good"], .int(1))
    }

    func testUnknownKeysAreIgnoredByConfig() {
        let c = Config.parse("""
        totally_unknown_key = "surprise"
        another = 99
        font_size = 18
        """)
        XCTAssertEqual(c.fontSize, 18)
        XCTAssertNil(c.fontFamily)
        XCTAssertEqual(c.scrollbackLines, 10_000)
    }

    func testOutOfRangeValuesKeepDefaults() {
        let c = Config.parse("""
        font_size = 2
        scrollback_lines = -5
        font_family = ""
        """)
        XCTAssertEqual(c.fontSize, 13)         // n > 4 guard
        XCTAssertEqual(c.scrollbackLines, 10_000)  // n >= 0 guard
        XCTAssertNil(c.fontFamily)             // empty string rejected
    }

    func testAnsiPaletteRequiresAllSixteen() {
        var toml = "[theme]\n"
        for i in 0..<15 { toml += "ansi\(i) = \"#00000\(String(i, radix: 16))\"\n" }
        XCTAssertNil(Config.parse(toml).ansiColors, "15 of 16 colors must not activate the palette")

        toml += "ansi15 = \"#ffffff\"\n"
        let full = Config.parse(toml).ansiColors
        XCTAssertEqual(full?.count, 16)
        XCTAssertEqual(full?[15], ConfigRGB(red: 255, green: 255, blue: 255))
    }

    // MARK: Font candidate fallback order

    func testResolveFontNamePrefersConfiguredFamily() {
        let name = Config.resolveFontName(preferred: "My Custom Font") { _ in true }
        XCTAssertEqual(name, "My Custom Font")
    }

    func testResolveFontNameFallsThroughCandidatesInOrder() {
        // Configured family not installed -> first installed candidate wins,
        // in declared order (nerd fonts before SF Mono before Menlo).
        let installed: Set<String> = ["SF Mono", "Menlo"]
        let name = Config.resolveFontName(preferred: "Not Installed") { installed.contains($0) }
        XCTAssertEqual(name, "SF Mono")

        let menloOnly = Config.resolveFontName(preferred: nil) { $0 == "Menlo" }
        XCTAssertEqual(menloOnly, "Menlo")

        let nerd = Config.resolveFontName(preferred: nil) { _ in true }
        XCTAssertEqual(nerd, Config.fontCandidates.first)
        XCTAssertEqual(nerd, "MesloLGS NF")
    }

    func testResolveFontNameNilWhenNothingInstalled() {
        XCTAssertNil(Config.resolveFontName(preferred: "X") { _ in false })
    }

    func testFontCandidateOrderIsNerdFirstMenloLast() {
        XCTAssertEqual(Config.fontCandidates.first, "MesloLGS NF")
        XCTAssertEqual(Config.fontCandidates.last, "Menlo")
        XCTAssertLessThan(Config.fontCandidates.firstIndex(of: "SF Mono")!,
                          Config.fontCandidates.firstIndex(of: "Menlo")!)
    }
}
