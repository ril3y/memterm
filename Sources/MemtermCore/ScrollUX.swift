import Foundation
import CoreGraphics

// SCROLL UX stage — pure logic seams (the TabStripLayout/SerialFooterModel
// extraction pattern, TESTING.md §1 placement rule):
//
//   1. MouseReportingPolicy — the predicate behind "selection survives
//      streaming output". SwiftTerm's view-level `allowMouseReporting` flag
//      doubles as "clear the native selection on every feed/linefeed"
//      (AppleTerminalView.feedPrepare + MacTerminalView.linefeed, verified in
//      SwiftTerm 1.20.0). memterm therefore derives the view flag from the
//      config intent AND whether an app actually enabled mouse tracking.
//   2. OverlayScrollerLayout / OverlayScrollerVisibility — geometry and the
//      clock-injected auto-hide state machine for the per-pane overlay
//      scrollbar. AppKit-free; the strip view is thin.

// MARK: - Selection-preservation predicate

public enum MouseReportingPolicy {
    /// The value SwiftTerm's `allowMouseReporting` should hold RIGHT NOW.
    ///
    /// `configured` is the user's `allow_mouse_reporting` intent;
    /// `mouseModeActive` is `terminal.mouseMode != .off` (an app such as vim
    /// or htop asked for the mouse). While no app tracks the mouse the flag
    /// stays false, so SwiftTerm's feed-time selection clears never fire and
    /// a selection stays anchored to buffer content across streaming output.
    /// Event routing is unchanged: every SwiftTerm mouse-forwarding site
    /// tests `allowMouseReporting && mouseMode.sendXxx()`, which is false
    /// anyway when the mode is off.
    public static func effectiveAllowMouseReporting(configured: Bool,
                                                    mouseModeActive: Bool) -> Bool {
        configured && mouseModeActive
    }
}

// MARK: - Overlay scroller geometry

/// Inputs for one layout pass. Lengths run along the track axis in TOP-ORIGIN
/// coordinates (the AppKit band view is flipped): offset 0 = top of the
/// track = oldest scrollback. `proportion` and `position` are SwiftTerm's
/// `scrollThumbsize` / `scrollPosition` (0 = scrolled to the top, 1 = live
/// bottom).
public struct OverlayScrollerMetrics: Equatable {
    public var trackLength: CGFloat
    public var proportion: CGFloat
    public var position: CGFloat

    public init(trackLength: CGFloat, proportion: CGFloat, position: CGFloat) {
        self.trackLength = trackLength
        self.proportion = proportion
        self.position = position
    }
}

public enum OverlayScrollerLayout {
    /// Width of the interactive band pinned to the pane's trailing edge.
    /// Terminal mouse events outside this band are never touched.
    public static let bandWidth: CGFloat = 12
    /// Drawn knob thickness inside the band.
    public static let knobThickness: CGFloat = 7
    public static let minKnobLength: CGFloat = 24
    public static let endInset: CGFloat = 3

    /// Knob placement along the track: (offset from the top, length).
    /// The knob is proportional to viewport/content but never shrinks below
    /// `minKnobLength`; nil when the track is too short to be useful.
    public static func knob(_ m: OverlayScrollerMetrics) -> (offset: CGFloat, length: CGFloat)? {
        let usable = m.trackLength - 2 * endInset
        guard usable >= minKnobLength else { return nil }
        let prop = min(max(m.proportion, 0), 1)
        let length = max(minKnobLength, (usable * prop).rounded())
        let travel = usable - length
        let pos = min(max(m.position, 0), 1)
        return (endInset + travel * pos, length)
    }

    /// Inverse map for a drag: where the knob's TOP edge sits → position.
    /// Clamped to 0...1; identity when there is no travel.
    public static func position(forKnobOffset offset: CGFloat,
                                metrics: OverlayScrollerMetrics) -> CGFloat {
        guard let knob = knob(metrics) else { return min(max(metrics.position, 0), 1) }
        let travel = (metrics.trackLength - 2 * endInset) - knob.length
        guard travel > 0 else { return 1 }
        return min(max((offset - endInset) / travel, 0), 1)
    }

    public enum TrackClick: Equatable {
        /// Above the knob → page toward older content.
        case pageUp
        /// Below the knob → page toward the live bottom.
        case pageDown
    }

    /// Classifies a click along the track; nil when the click lands on the
    /// knob itself (that is a drag, not a page).
    public static func trackClick(at offset: CGFloat,
                                  metrics: OverlayScrollerMetrics) -> TrackClick? {
        guard let knob = knob(metrics) else { return nil }
        if offset < knob.offset { return .pageUp }
        if offset > knob.offset + knob.length { return .pageDown }
        return nil
    }
}

// MARK: - Auto-hide state machine (injected clock)

public struct OverlayScrollerVisibility {
    public var fadeDelay: TimeInterval
    public private(set) var lastActivity: TimeInterval?
    /// A knob drag pins the bar visible for its whole duration.
    public var isDragging = false
    /// Hovering the band pins it visible (macOS overlay-scroller behavior).
    public var isHovering = false

    public init(fadeDelay: TimeInterval = 1.0) {
        self.fadeDelay = fadeDelay
    }

    public mutating func noteActivity(now: TimeInterval) {
        lastActivity = now
    }

    /// Never seen activity → hidden (a fresh pane shows no bar).
    public func visible(now: TimeInterval) -> Bool {
        if isDragging || isHovering { return true }
        guard let last = lastActivity else { return false }
        return now - last < fadeDelay
    }

    /// The uptime at which the bar should fade, or nil when no timed
    /// transition is pending (hidden already, or pinned by drag/hover).
    public func nextFadeDeadline(now: TimeInterval) -> TimeInterval? {
        guard !isDragging, !isHovering, let last = lastActivity,
              visible(now: now) else { return nil }
        return last + fadeDelay
    }
}
