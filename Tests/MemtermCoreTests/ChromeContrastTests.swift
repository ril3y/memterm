import XCTest
@testable import MemtermCore

// TESTING.md L2 seam (b): chip contrast math. The bug-2 regression: chips
// invisible at window_opacity 0.37 — under memterm's chrome-rows-stay-opaque
// rule the chip contrast must clear the floor at EVERY legal opacity, and the
// test also demonstrates the buggy (translucent-row) model fails at 0.37, so
// this suite would have caught the escape.
final class ChromeContrastTests: XCTestCase {
    // memterm-dark defaults: light label on the dark chrome row.
    private let text = ConfigRGB(hex: "#c5c8c6")!
    private let row = ConfigRGB(hex: "#1d1f21")!

    func testWcagAnchors() {
        let black = ConfigRGB(red: 0, green: 0, blue: 0)
        let white = ConfigRGB(red: 255, green: 255, blue: 255)
        XCTAssertEqual(ChromeContrast.contrastRatio(black, white), 21.0, accuracy: 0.01)
        XCTAssertEqual(ChromeContrast.contrastRatio(white, white), 1.0, accuracy: 0.01)
    }

    /// REGRESSION (founder bug 2): with the chrome row kept opaque, chip
    /// contrast clears the floor across the ENTIRE legal opacity range —
    /// including the founder's 0.37.
    func testOpaqueChromeRowHoldsFloorAcrossOpacityRange() {
        var opacity = Config.windowOpacityRange.lowerBound
        while opacity <= Config.windowOpacityRange.upperBound + 0.0001 {
            let ratio = ChromeContrast.chipContrast(
                text: text, rowBackground: row, windowOpacity: opacity,
                chromeRowOpaque: true)
            XCTAssertGreaterThanOrEqual(ratio, ChromeContrast.minimumChipContrast,
                "chip contrast \(ratio) below floor at opacity \(opacity)")
            opacity += 0.01
        }
    }

    /// The shipped bug, modeled: a translucent chrome row over a light
    /// desktop washes the chips out at 0.37 — the floor check FAILS, which is
    /// exactly why this assertion existed nowhere and the bug reached the
    /// founder. Calibration: "would this have caught it?" — yes.
    func testTranslucentChromeRowFailsAtFounderOpacity() {
        let ratio = ChromeContrast.chipContrast(
            text: text, rowBackground: row, windowOpacity: 0.37,
            chromeRowOpaque: false)
        XCTAssertLessThan(ratio, ChromeContrast.minimumChipContrast,
            "the buggy model unexpectedly passes — the regression test lost its teeth")
    }

    func testCompositeEndpoints() {
        let white = ConfigRGB(red: 255, green: 255, blue: 255)
        XCTAssertEqual(ChromeContrast.composite(row, over: white, alpha: 1.0), row)
        XCTAssertEqual(ChromeContrast.composite(row, over: white, alpha: 0.0), white)
    }
}
