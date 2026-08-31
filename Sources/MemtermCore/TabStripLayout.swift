import Foundation

// Custom-tab-chrome stage (founder-approved rearchitecture): pure layout math
// for the in-window tab strip, kept AppKit-free so it is testable headlessly.
//
// Model (Safari-like): tabs share the strip width equally, squeezing as tabs
// are added down to a 72 pt floor; below the floor the strip stops squeezing
// and becomes horizontally scrollable (every tab stays at the floor width).
// Hit-testing and drag-reorder index math live here too, so the AppKit strip
// view is only a renderer.

public struct TabStripLayout: Equatable {
    /// Narrowest a tab body may get before the strip scrolls instead.
    public static let minTabWidth: Double = 72
    /// Widest a tab body ever gets (a lone tab doesn't span a huge window).
    public static let maxTabWidth: Double = 220
    /// Gap between tab bodies.
    public static let tabGap: Double = 4

    public let tabWidth: Double
    public let tabCount: Int
    /// True when the tabs no longer fit at the floor width: the strip view
    /// should scroll horizontally (hidden scrollers, edge fade).
    public let needsScroll: Bool
    /// Total width of the laid-out tab row (may exceed `available` when
    /// scrolling).
    public let contentWidth: Double

    public init(available: Double, count: Int) {
        tabCount = max(0, count)
        guard tabCount > 0, available > 0 else {
            tabWidth = 0
            needsScroll = false
            contentWidth = 0
            return
        }
        let gaps = Double(tabCount - 1) * Self.tabGap
        let equal = (available - gaps) / Double(tabCount)
        let width = min(Self.maxTabWidth, equal)
        if width < Self.minTabWidth {
            tabWidth = Self.minTabWidth
            needsScroll = true
        } else {
            tabWidth = width
            needsScroll = false
        }
        contentWidth = Double(tabCount) * tabWidth + gaps
    }

    /// Leading x of tab `index` within the strip's content coordinates.
    public func xOrigin(of index: Int) -> Double {
        Double(index) * (tabWidth + Self.tabGap)
    }

    /// The tab under content-coordinate `x`, or nil for a gap / trailing
    /// space (background clicks drag the window, they never select).
    public func hitTest(x: Double) -> Int? {
        guard tabCount > 0, x >= 0 else { return nil }
        let slot = tabWidth + Self.tabGap
        let index = Int(x / slot)
        guard index < tabCount else { return nil }
        let inTab = x - Double(index) * slot
        return inTab <= tabWidth ? index : nil
    }

    /// Drag-reorder: the index the dragged tab should occupy while its center
    /// sits at content-coordinate `x`. Clamped to the valid range.
    public func dropIndex(forDragCenterX x: Double) -> Int {
        guard tabCount > 0 else { return 0 }
        let slot = tabWidth + Self.tabGap
        let index = Int((x / slot).rounded(.down))
        return min(max(index, 0), tabCount - 1)
    }
}

public enum TabTint {
    /// Whether a label over an sRGB fill of this color should be dark
    /// (black) rather than light (white) — the same 0.299/0.587/0.114
    /// luminance flip the attributed-title pill used.
    public static func useDarkText(red: Double, green: Double, blue: Double) -> Bool {
        (0.299 * red + 0.587 * green + 0.114 * blue) > 0.55
    }
}

/// Pure reorder math shared by the strip view and tests: moves the element at
/// `from` so it lands at `to` (indices in the pre-move array).
public enum TabReorder {
    public static func move<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to),
              from != to else { return items }
        var result = items
        let item = result.remove(at: from)
        result.insert(item, at: to)
        return result
    }
}
