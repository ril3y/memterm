import SwiftUI
import MemtermRemoteApp
import MemtermRemoteKit

/// One paired Mac's workspace tree: every pane, grouped by workspace. Serial
/// panes and panes in a locked workspace are shown disabled, with a footnote
/// saying why, rather than being filtered out — so the person sees their
/// whole Mac, not a filtered half of it (task 4 self-review). Tapping an
/// attachable row attaches and pushes `TerminalScreen`. Nothing here ever
/// calls `session.resize` — see `TerminalViewHost`'s header comment for where
/// that rule actually lives.
struct TreeView: View {
    @ObservedObject var session: HostSession
    let host: PairedHost

    /// The pane this screen has pushed `TerminalScreen` for. `nil` pops back
    /// here — set by a row tap, cleared by `TerminalScreen`'s own dismiss
    /// (Back, the Mac closing the pane, or a swipe-back).
    @State private var attachedPaneId: String?
    /// A brief notice shown after `TerminalScreen` auto-pops because the Mac
    /// closed the pane out from under the viewer — otherwise that return to
    /// the tree looks identical to pressing Back, which is confusing. Clears
    /// itself after a few seconds, or immediately on refresh.
    @State private var closedPaneNotice: String?

    var body: some View {
        List {
            if let banner = statusBanner {
                Section {
                    Label(banner, systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                }
            }
            if let closedPaneNotice {
                Section {
                    Text(closedPaneNotice)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(sections, id: \.workspaceName) { section in
                Section(section.workspaceName) {
                    ForEach(section.rows) { row in
                        Button {
                            attach(row)
                        } label: {
                            TreeRow(row: row, disabledReason: row.attachable ? nil : reason(for: row))
                        }
                        .disabled(!row.attachable)
                        .buttonStyle(.plain)
                    }
                }
            }
            if sections.isEmpty && statusBanner == nil {
                Section {
                    Text("No windows are open on \(host.name) right now.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(host.name)
        .navigationDestination(item: $attachedPaneId) { paneId in
            TerminalScreen(session: session, paneId: paneId, onPaneClosedByHost: {
                closedPaneNotice = "That pane was closed on \(host.name)."
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if closedPaneNotice != nil { closedPaneNotice = nil }
                }
            })
        }
        .refreshable {
            closedPaneNotice = nil
            session.start()
        }
    }

    // MARK: - Rows

    private func attach(_ row: ViewerRow) {
        closedPaneNotice = nil
        session.attach(paneId: row.id)
        attachedPaneId = row.id
    }

    private var sections: [(workspaceName: String, rows: [ViewerRow])] {
        guard let tree = session.tree else { return [] }
        let rows = ViewerTree.rows(from: tree)
        var order: [String] = []
        var grouped: [String: [ViewerRow]] = [:]
        for row in rows {
            if grouped[row.workspaceName] == nil { order.append(row.workspaceName) }
            grouped[row.workspaceName, default: []].append(row)
        }
        return order.map { (workspaceName: $0, rows: grouped[$0] ?? []) }
    }

    private var lockedWorkspaceNames: Set<String> {
        Set((session.tree?.workspaces ?? []).filter(\.locked).map(\.name))
    }

    /// `ViewerRow` carries no workspace id and no explicit "why disabled"
    /// flag, only `attachable`. The two reasons `ViewerTree.rows` computes it
    /// from are each independently recoverable here: a locked workspace from
    /// `session.tree` by name, and a serial pane from the adapter name
    /// `subtitle` already carries verbatim. If a workspace is both locked AND
    /// the pane is serial, the workspace reason wins — it is the broader
    /// fact, and true of every row in that section.
    private func reason(for row: ViewerRow) -> String {
        if lockedWorkspaceNames.contains(row.workspaceName) {
            return "This workspace is locked."
        }
        return "Serial panes can't be attached yet."
    }

    private var statusBanner: String? {
        switch session.phase {
        case .offline(let since):
            if let since {
                return "\(host.name) has been offline since \(since.formatted(date: .omitted, time: .shortened))."
            }
            return "\(host.name) is offline."
        case .failed(let reason):
            return reason
        default:
            return nil
        }
    }
}

private struct TreeRow: View {
    let row: ViewerRow
    let disabledReason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title)
                .font(.body)
            Text(row.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let disabledReason {
                Text(disabledReason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .opacity(row.attachable ? 1 : 0.5)
    }
}
