import Foundation

/// Which workspaces belong on the bar, and which belong under Parked.
///
/// Founder ask 2026-10-02: a parked workspace leaves the workspace bar and
/// becomes reachable from a Parked section of the menu instead. These two
/// lists partition the store's workspaces, so nothing can fall between them
/// and become unreachable.
///
/// Taking parked workspaces off the bar also retires an older reported
/// defect rather than guarding it: clicking a parked chip used to un-park it,
/// and the founder asked for un-park to move behind a right-click. With no
/// parked chip on the bar there is nothing to mis-click.
public enum WorkspaceVisibility {

    /// The workspaces to render as chips.
    ///
    /// The active workspace is always included, even when it is marked
    /// parked. That is not defensive padding: `workspaceEmptiedByUserClose`
    /// sets the parked flag while `activeWorkspaceId` may still name that
    /// workspace, because the switch away is deferred to the MRU surfacing.
    /// Hiding it on that path would blank the bar's own active chip for a
    /// moment, and the app always has a window, so the bar must always have a
    /// chip.
    public static func barRows(_ workspaces: [WorkspaceRow], activeId: String) -> [WorkspaceRow] {
        workspaces.filter { !$0.isParked || $0.id == activeId }
    }

    /// The workspaces to list under Parked. Exactly the complement of
    /// `barRows`, in the store's own order so the list does not shuffle
    /// between opens.
    public static func parkedRows(_ workspaces: [WorkspaceRow], activeId: String) -> [WorkspaceRow] {
        workspaces.filter { $0.isParked && $0.id != activeId }
    }
}
