import Foundation

/// Resolving a dragged tab's drop against the workspace bar.
///
/// Pure on purpose: the AppKit side owns the drag session, the highlight and
/// the actual move, and asks this only "what is under the cursor". That keeps
/// the part with rules in it testable, because the part with `NSDraggingInfo`
/// in it is not.
///
/// Axis-agnostic on purpose too. The bar is a horizontal strip today and an
/// Appearance option stacks it vertically (founder ask 2026-10-02) while the
/// tab strip stays horizontal along the top. The drop rules do not change
/// between those two, only which coordinate runs along the bar, so the
/// sidebar inherits this instead of growing a second copy that drifts.
public enum WorkspaceBarDrop {

    /// Which coordinate runs along the bar.
    public enum Axis: Sendable {
        case horizontal
        case vertical
    }

    public enum Target: Equatable, Sendable {
        /// Not over the bar; the drag should be refused here.
        case outside
        /// Move the dragged tab to this workspace.
        case workspace(id: String)
        /// The bare stretch of bar: ask for a name, create a workspace, and
        /// move the tab into it.
        case newWorkspace
    }

    /// `chips` are the workspace chips' own frames, in the same coordinate
    /// space as `point` and `bounds`. Order does not matter: the run of chips
    /// is found from their frames, never from their position in the array, so
    /// a bar that lays out right-to-left or top-down behaves identically.
    public static func target(at point: CGPoint,
                              bounds: CGRect,
                              chips: [(id: String, frame: CGRect)],
                              axis: Axis) -> Target {
        guard bounds.contains(point) else { return .outside }

        // A chip under the cursor wins outright.
        if let hit = chips.first(where: { $0.frame.contains(point) }) {
            return .workspace(id: hit.id)
        }
        guard !chips.isEmpty else { return .newWorkspace }

        // Off the chips. The question is whether the cursor is in a gap
        // between them (a near miss) or out on the bare bar (the new-
        // workspace gesture), and that is decided along the bar's own axis.
        let cursor = along(point, axis)
        let starts = chips.map { along($0.frame.origin, axis) }
        let ends = chips.map { along(CGPoint(x: $0.frame.maxX, y: $0.frame.maxY), axis) }
        guard let runStart = starts.min(), let runEnd = ends.max() else { return .newWorkspace }

        // Beyond the run in either direction is bare bar. Both ends count:
        // the leading end is just as empty as the trailing one, and deciding
        // by direction would lose the gesture on a bar that grows the other
        // way.
        guard cursor >= runStart, cursor <= runEnd else { return .newWorkspace }

        // Inside the run but not inside a chip: the inter-chip gap. A few
        // points of gap is a near miss, so fall to the closest chip rather
        // than silently offering to create a workspace the person did not
        // ask for.
        let nearest = chips.min { lhs, rhs in
            distance(from: cursor, toChipAlong: lhs.frame, axis: axis)
                < distance(from: cursor, toChipAlong: rhs.frame, axis: axis)
        }
        guard let nearest else { return .newWorkspace }
        return .workspace(id: nearest.id)
    }

    private static func along(_ point: CGPoint, _ axis: Axis) -> CGFloat {
        axis == .horizontal ? point.x : point.y
    }

    /// Distance from a position along the bar to a chip's span along the bar,
    /// zero when inside it.
    private static func distance(from along: CGFloat, toChipAlong frame: CGRect, axis: Axis) -> CGFloat {
        let lo = axis == .horizontal ? frame.minX : frame.minY
        let hi = axis == .horizontal ? frame.maxX : frame.maxY
        if along < lo { return lo - along }
        if along > hi { return along - hi }
        return 0
    }
}
