import Foundation

// L2 headless seam (TESTING.md §2 / bug 2 regression): chrome contrast as
// pure math. The founder bug: at window_opacity 0.37 the workspace chips
// washed out to invisible — a visual truth no model-level assertion saw. The
// fix keeps the chrome rows opaque under window transparency; this seam pins
// the RULE down headlessly (chip contrast must clear a floor at every legal
// opacity), and the probe's rendered-bitmap chip step checks AppKit obeys.
public enum ChromeContrast {
    /// WCAG floor for large/bold UI text. The probe's rendered-bitmap check
    /// uses a looser 1.6 (sampled composited pixels); the pure math here is
    /// exact so it can hold the real bar.
    public static let minimumChipContrast = 3.0

    /// WCAG relative luminance of an sRGB color.
    public static func relativeLuminance(_ c: ConfigRGB) -> Double {
        func channel(_ v: Int) -> Double {
            let s = Double(v) / 255.0
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green)
            + 0.0722 * channel(c.blue)
    }

    /// WCAG contrast ratio, 1.0 (identical) … 21.0 (black/white).
    public static func contrastRatio(_ a: ConfigRGB, _ b: ConfigRGB) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Council #2 ("two apps stacked"): the chrome rows ground themselves on
    /// the THEME background, so the window's appearance — which decides every
    /// semantic AppKit color the chips/tabs/labels use — must be keyed from
    /// the same place. Light theme ground → light chrome; dark (or no) theme
    /// → dark chrome (memterm's default palette is dark).
    public static func prefersLightChrome(themeBackground: ConfigRGB?) -> Bool {
        guard let bg = themeBackground else { return false }
        return relativeLuminance(bg) > 0.5
    }

    /// Council #8: split dividers must stay visible on EVERY theme ground —
    /// the founder bug was near-invisible dividers in dark themes, where the
    /// system separator color sits within noise of the terminal background.
    /// The floor matches the probe's rendered chip floor: comfortably above
    /// AA/pixel noise, below "drawing attention to itself".
    public static let minimumDividerContrast = 1.6

    /// A divider gray derived FROM the theme background with the contrast
    /// floor guaranteed: the minimal blend of white (over a dark ground) or
    /// black (over a light ground) that clears `minimumDividerContrast`.
    /// nil theme = memterm's default near-black ground.
    public static func dividerColor(themeBackground: ConfigRGB?) -> ConfigRGB {
        let bg = themeBackground ?? ConfigRGB(red: 0, green: 0, blue: 0)
        let toward = relativeLuminance(bg) > 0.5
            ? ConfigRGB(red: 0, green: 0, blue: 0)
            : ConfigRGB(red: 255, green: 255, blue: 255)
        var candidate = bg
        // Walk alpha up in fine steps until the floor holds (monotone in
        // alpha, so the first pass is the minimal visible divider).
        var alpha = 0.0
        while contrastRatio(candidate, bg) < minimumDividerContrast, alpha < 1.0 {
            alpha += 0.02
            candidate = composite(toward, over: bg, alpha: alpha)
        }
        return candidate
    }

    /// `a` composited over `b` at `alpha` (simple source-over, per channel).
    public static func composite(_ a: ConfigRGB, over b: ConfigRGB,
                                 alpha: Double) -> ConfigRGB {
        let k = min(max(alpha, 0), 1)
        func mix(_ x: Int, _ y: Int) -> Int {
            Int((Double(x) * k + Double(y) * (1 - k)).rounded())
        }
        return ConfigRGB(red: mix(a.red, b.red), green: mix(a.green, b.green),
                         blue: mix(a.blue, b.blue))
    }

    /// Effective contrast between chip text and what the chip actually sits
    /// on, under `windowOpacity`.
    ///
    /// - `chromeRowOpaque: true` is memterm's rule (the 2026-09-01 fix): the
    ///   chrome rows keep a solid ground regardless of window opacity, so the
    ///   ratio is opacity-INDEPENDENT.
    /// - `chromeRowOpaque: false` models the shipped bug: the row background
    ///   composites toward whatever is behind the window (`behind`, worst
    ///   case near-white desktop), and text contrast decays with opacity —
    ///   at 0.37 it falls below any readable floor. The regression test
    ///   asserts exactly that asymmetry.
    public static func chipContrast(text: ConfigRGB, rowBackground: ConfigRGB,
                                    windowOpacity: Double,
                                    chromeRowOpaque: Bool,
                                    behind: ConfigRGB = ConfigRGB(red: 240, green: 240, blue: 240))
        -> Double {
        let effectiveBackground = chromeRowOpaque
            ? rowBackground
            : composite(rowBackground, over: behind, alpha: windowOpacity)
        return contrastRatio(text, effectiveBackground)
    }
}
