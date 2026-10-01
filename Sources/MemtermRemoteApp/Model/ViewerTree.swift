import Foundation
import MemtermRemoteKit

/// The flattened rows a viewer shows: one section per workspace, one row per
/// attachable pane. Built here rather than in the view so it is testable.
public struct ViewerRow: Equatable, Identifiable {
    public var id: String            // paneId
    public var workspaceName: String
    public var workspaceColor: String
    public var title: String         // tab title
    public var subtitle: String      // adapter · cwd
    public var attachable: Bool      // serial and locked panes are shown, disabled
}

public enum ViewerTree {
    /// Serial panes cannot be attached (their bytes do not pass the taps a
    /// viewer reads), and locked workspaces refuse; both are listed anyway so
    /// the person sees their whole Mac rather than a filtered half of it.
    public static func rows(from tree: RemoteTree) -> [ViewerRow] {
        tree.workspaces.flatMap { workspace in
            workspace.windows.flatMap { window in
                window.tabs.flatMap { tab in
                    tab.panes.map { pane in
                        ViewerRow(id: pane.id,
                                  workspaceName: workspace.name,
                                  workspaceColor: workspace.color,
                                  title: tab.title,
                                  subtitle: pane.cwd.map { "\(pane.adapter) · \($0)" } ?? pane.adapter,
                                  attachable: pane.adapter != "serial" && !workspace.locked)
                    }
                }
            }
        }
    }

    public static func contains(paneId: String, in tree: RemoteTree) -> Bool {
        rows(from: tree).contains { $0.id == paneId }
    }
}
