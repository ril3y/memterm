import Foundation

// Founder UX stage (2026-08-31): "if stuff is happening on a tab (like text
// scrolling) lets have the title shake a bit or show a spinner or something".
// This is the pure state machine behind the per-tab activity indicator; the
// AppKit face (TabActivityIndicatorView, spinner / unseen dot inside the
// custom tab strip's TabItemView) lives in the executable target.
//
// States:
//   .active — pty output flowed within `decayInterval` on a NON-selected tab
//             (rendered as a spinner);
//   .unseen — output stopped but the tab hasn't been selected since
//             (rendered as a solid dot);
//   .idle   — nothing to show (selected tabs are always idle).
//
// UI publishing is coalesced: `recordOutput` returns true at most once per
// `coalesceInterval`, so a flood of pty chunks costs at most ~4 UI updates/s.

public enum TabActivityState: Equatable {
    case idle
    case active
    case unseen
}

public struct TabActivityTracker {
    public let decayInterval: TimeInterval
    public let coalesceInterval: TimeInterval

    private var lastOutputAt: TimeInterval?
    private var hasUnseenOutput = false
    private var lastPublishAt: TimeInterval?

    public init(decayInterval: TimeInterval = 1.5, coalesceInterval: TimeInterval = 0.25) {
        self.decayInterval = decayInterval
        self.coalesceInterval = coalesceInterval
    }

    /// Output arrived at `t`. Returns true when the UI should repaint NOW;
    /// false means the mark was recorded but coalesced (the caller repaints on
    /// its next scheduled tick). Output on a selected tab never marks — it is
    /// being watched — and clears any stale state.
    public mutating func recordOutput(at t: TimeInterval, isSelected: Bool) -> Bool {
        if isSelected {
            let hadSomething = lastOutputAt != nil || hasUnseenOutput
            lastOutputAt = nil
            hasUnseenOutput = false
            lastPublishAt = nil
            return hadSomething
        }
        lastOutputAt = t
        hasUnseenOutput = true
        if let last = lastPublishAt, t - last < coalesceInterval {
            return false
        }
        lastPublishAt = t
        return true
    }

    /// The tab was selected: everything is seen, indicator clears.
    public mutating func recordSelected() {
        lastOutputAt = nil
        hasUnseenOutput = false
        lastPublishAt = nil
    }

    public func state(at t: TimeInterval) -> TabActivityState {
        if let last = lastOutputAt, t - last < decayInterval {
            return .active
        }
        return hasUnseenOutput ? .unseen : .idle
    }

    /// The instant the current .active state decays to .unseen; nil when not
    /// active. Callers schedule one repaint just after this.
    public func nextDecay(after t: TimeInterval) -> TimeInterval? {
        guard let last = lastOutputAt, t - last < decayInterval else { return nil }
        return last + decayInterval
    }
}
