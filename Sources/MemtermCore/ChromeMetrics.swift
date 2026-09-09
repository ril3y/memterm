import Foundation

// Founder bug (2026-09-09): "the settings in appearance sets the size of the
// text but the tabs/workspace does not really abide by this setting". The
// chrome rows (workspace chips, tab pills, their row heights and decorations)
// were pinned at the sizes tuned for the 13pt default terminal font. This is
// the single source of truth that scales them off the CONFIGURED terminal
// size (Settings › Appearance › Size — not the transient ⌘+/⌘- zoom, which
// is a pane-only gesture).
//
// Invariants (council #10, gated by the chip-pill-hierarchy probe leg):
//   chip font  <  pill font          (chips read one level BELOW the pills)
//   chip height <  pill height
// so the derivation keeps the chip exactly one point under the pill at every
// scale, and the "(parked)" suffix one point under the chip.
public struct ChromeMetrics: Equatable {
    /// The terminal size the hand-tuned chrome design was drawn against.
    public static let referenceTerminalSize: Double = 13
    /// Tab-pill label size at the reference terminal size.
    public static let referencePillSize: Double = 11
    /// Chrome text never drops below this even for tiny terminal fonts.
    public static let minimumPillSize: Double = 10

    /// Tab-pill label point size.
    public let pillFontSize: Double
    /// Workspace-chip label point size (pill − 1).
    public let chipFontSize: Double
    /// The dimmed "(parked)" suffix (chip − 1).
    public let chipSuffixFontSize: Double
    /// Row height of the tab strip (30 at reference).
    public let tabStripHeight: Double
    /// Row height of the workspace bar (26 at reference).
    public let workspaceBarHeight: Double
    /// A chip pill's height (19 at reference).
    public let chipHeight: Double
    /// Baseline offset that optically centers the chip label (3.85 at
    /// reference; positive-down in AppKit autolayout).
    public let chipBaselineOffset: Double

    /// Multiplier for decorations (dots, rings, close glyphs, insets) that
    /// were drawn against the reference pill size.
    public var scale: Double { pillFontSize / Self.referencePillSize }

    public static func derived(fromTerminalFontSize size: Double) -> ChromeMetrics {
        let ratio = max(size, 1) / referenceTerminalSize
        let pill = max(minimumPillSize, (referencePillSize * ratio).rounded())
        let chip = pill - 1
        let scale = pill / referencePillSize
        return ChromeMetrics(
            pillFontSize: pill,
            chipFontSize: chip,
            chipSuffixFontSize: chip - 1,
            tabStripHeight: (30 * scale).rounded(),
            workspaceBarHeight: (26 * scale).rounded(),
            chipHeight: (19 * scale).rounded(),
            chipBaselineOffset: 3.85 * (chip / 10))
    }

    /// The reference design, verbatim (13pt terminal → 11/10pt chrome).
    public static let reference = derived(fromTerminalFontSize: referenceTerminalSize)
}
