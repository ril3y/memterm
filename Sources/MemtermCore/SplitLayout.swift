import Foundation
import CoreGraphics

// L2 headless seam (TESTING.md §2 / bug 1 regression): split-tree layout as a
// pure function. The AppKit side (TerminalWindowController's NSSplitView
// tree) must agree with this math; the probe's at-launch geometry step is the
// check that AppKit obeys. The invariant this seam exists to pin down:
// **no pane may lay out to zero size inside a non-zero container** — the
// restored-split collapse (0x0 container at attach re-expanded with ALL width
// on the first pane) shipped precisely because no headless test owned this.
public enum SplitLayout {
    /// The smallest side a pane may be given when the container can afford
    /// it. Matches the probe's assertPaneGeometry floor.
    public static let minPaneSide: CGFloat = 50

    /// Lays out `tree` into `container`, returning each pane's rect.
    /// - `vertical: true` splits side-by-side (divides width, first child on
    ///   the left) — the app's "split right"; `false` stacks (divides height,
    ///   first child on top).
    /// - The split ratio is clamped so that whenever the divided side is
    ///   non-zero, BOTH children get a non-zero share (at least
    ///   `min(minPaneSide, side/2)` each). A zero container yields zero rects
    ///   for every pane — the invariant is conditional on a real container.
    public static func layout(tree: SplitNode, container: CGRect,
                              minSide: CGFloat = SplitLayout.minPaneSide)
        -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        place(tree, in: container, minSide: minSide, into: &result)
        return result
    }

    private static func place(_ node: SplitNode, in rect: CGRect,
                              minSide: CGFloat, into result: inout [String: CGRect]) {
        switch node {
        case .pane(let id):
            result[id] = rect
        case .split(let vertical, let ratio, let first, let second):
            let side = vertical ? rect.width : rect.height
            let firstShare = clampedFirstShare(side: side, ratio: ratio,
                                               minSide: minSide)
            if vertical {
                let a = CGRect(x: rect.minX, y: rect.minY,
                               width: firstShare, height: rect.height)
                let b = CGRect(x: rect.minX + firstShare, y: rect.minY,
                               width: side - firstShare, height: rect.height)
                place(first, in: a, minSide: minSide, into: &result)
                place(second, in: b, minSide: minSide, into: &result)
            } else {
                let a = CGRect(x: rect.minX, y: rect.minY,
                               width: rect.width, height: firstShare)
                let b = CGRect(x: rect.minX, y: rect.minY + firstShare,
                               width: rect.width, height: side - firstShare)
                place(first, in: a, minSide: minSide, into: &result)
                place(second, in: b, minSide: minSide, into: &result)
            }
        }
    }

    /// The first child's share of a divided side: `side * ratio`, clamped so
    /// both children keep at least `min(minSide, side/2)` whenever side > 0.
    /// This is the line of math that makes the zero-collapse structurally
    /// impossible: for ANY ratio (0, 1, NaN-free garbage clamped upstream),
    /// a positive side always divides into two positive shares.
    public static func clampedFirstShare(side: CGFloat, ratio: Double,
                                         minSide: CGFloat = SplitLayout.minPaneSide)
        -> CGFloat {
        guard side > 0 else { return 0 }
        let floorShare = Swift.min(minSide, side / 2)
        let raw = side * CGFloat(ratio.isFinite ? ratio : 0.5)
        return Swift.min(Swift.max(raw, floorShare), side - floorShare)
    }
}
