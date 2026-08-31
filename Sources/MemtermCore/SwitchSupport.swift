import CoreGraphics
import Foundation

// FR-59 pure logic, AppKit-free so it is testable headlessly:
//  - journaled-frame placement for the resurrect path (windows never jump;
//    only a frame that would land fully off-screen gets adjusted), and
//  - the most-recently-used hidden-workspace pick for the last-visible-window
//    corollary (the app never sits windowless while hidden live windows exist).

public enum SwitchSupport {

    /// Frame stability (FR-59): a journaled frame is used exactly as stored
    /// unless it lands entirely outside every screen's visible area — then it
    /// is clamped onto the first (main) screen, shrinking only if it is bigger
    /// than that screen. With no screens (headless), the frame passes through.
    public static func adjustedFrame(_ frame: CGRect, visibleFrames: [CGRect]) -> CGRect {
        guard !visibleFrames.isEmpty else { return frame }
        if visibleFrames.contains(where: { $0.intersects(frame) }) { return frame }
        let screen = visibleFrames[0]
        var adjusted = frame
        adjusted.size.width = min(adjusted.width, screen.width)
        adjusted.size.height = min(adjusted.height, screen.height)
        adjusted.origin.x = min(max(adjusted.minX, screen.minX), screen.maxX - adjusted.width)
        adjusted.origin.y = min(max(adjusted.minY, screen.minY), screen.maxY - adjusted.height)
        return adjusted
    }

    /// The workspace to surface when the active workspace's last visible
    /// window closes: the most recently used candidate (`mostRecentFirst` is
    /// newest-first), falling back to the alphabetically first candidate so
    /// the pick is deterministic even with no MRU history. nil = no candidates.
    public static func mruPick(candidates: Set<String>, mostRecentFirst: [String]) -> String? {
        guard !candidates.isEmpty else { return nil }
        if let hit = mostRecentFirst.first(where: { candidates.contains($0) }) { return hit }
        return candidates.sorted().first
    }
}
