import Foundation

// Founder UX stage: "the ping command always creates activity — the non-front
// workspace should blink the color circle or something". Pure state machine
// behind the workspace-bar chip activity marks, sharing TabActivityTracker's
// decay/coalescing semantics (one tracker per workspace):
//
//   .active — pty output flowed within decayInterval in a NON-active
//             workspace (chip dot pulses);
//   .unseen — output stopped but the workspace hasn't been switched to since
//             (persistent ring around the dot);
//   .idle   — nothing to show. The ACTIVE workspace never indicates: the
//             user is looking at it.
//
// The AppKit face (pulse animation / ring on WorkspaceChipView) lives in the
// executable target.

public struct WorkspaceActivityCenter {
    public let decayInterval: TimeInterval
    public let coalesceInterval: TimeInterval

    private var trackers: [String: TabActivityTracker] = [:]

    public init(decayInterval: TimeInterval = 1.5, coalesceInterval: TimeInterval = 0.25) {
        self.decayInterval = decayInterval
        self.coalesceInterval = coalesceInterval
    }

    /// Output arrived in workspace `id` at `t`. Returns true when the chips
    /// should repaint NOW (coalesced to ≤1 publish per coalesceInterval per
    /// workspace — flood output never churns the bar). Output in the ACTIVE
    /// workspace never marks and clears any stale state, exactly like a
    /// selected tab in TabActivityTracker.
    public mutating func recordOutput(workspace id: String, at t: TimeInterval,
                                      isActiveWorkspace: Bool) -> Bool {
        var tracker = trackers[id] ?? TabActivityTracker(decayInterval: decayInterval,
                                                         coalesceInterval: coalesceInterval)
        let publish = tracker.recordOutput(at: t, isSelected: isActiveWorkspace)
        trackers[id] = tracker
        return publish
    }

    /// The user switched to workspace `id`: everything there is seen.
    public mutating func recordSwitched(to id: String) {
        trackers[id]?.recordSelected()
    }

    /// A workspace that no longer exists (forgotten) drops its state.
    public mutating func removeWorkspace(_ id: String) {
        trackers[id] = nil
    }

    public func state(of id: String, at t: TimeInterval) -> TabActivityState {
        trackers[id]?.state(at: t) ?? .idle
    }

    /// Earliest pending active→unseen transition across all workspaces; nil
    /// when none is active. Callers schedule one repaint just after this.
    public func nextDecay(after t: TimeInterval) -> TimeInterval? {
        trackers.values.compactMap { $0.nextDecay(after: t) }.min()
    }
}
