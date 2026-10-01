import SwiftUI
import MemtermRemoteApp

/// The app's home screen: every Mac this device has been allowed into.
/// Tapping a row pushes a placeholder that starts `HostSession` and shows
/// its `phase` — `TreeView` (Task 4) replaces that placeholder without
/// touching anything here.
struct MacsView: View {
    @ObservedObject var model: AppModel

    @State private var isPresentingPair = false
    /// The host a swipe-to-delete is confirming removal of. A sheet/alert
    /// keyed by an optional id, rather than a bare `Bool`, so the
    /// confirmation always names the right row even if the list reorders
    /// while it is up.
    @State private var pendingRemoval: PairedHost?

    var body: some View {
        NavigationStack {
            Group {
                if model.hosts.isEmpty {
                    ContentUnavailableView(
                        "No Paired Macs",
                        systemImage: "desktopcomputer",
                        description: Text("Tap + and scan the pairing code memterm shows on your Mac.")
                    )
                } else {
                    List {
                        ForEach(model.hosts) { host in
                            NavigationLink {
                                MacSessionPlaceholderView(model: model, host: host)
                            } label: {
                                MacRow(host: host)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    pendingRemoval = host
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Macs")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPresentingPair = true
                    } label: {
                        Label("Pair a Mac", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingPair) {
                PairView(model: model)
            }
            .confirmationDialog(
                "Remove \(pendingRemoval?.name ?? "this Mac")?",
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    if let id = pendingRemoval?.id { model.remove(id: id) }
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Removing it here does not revoke it on the Mac. The Mac will still list this device until you remove it there too.")
            }
        }
        .onAppear { model.reloadHosts() }
    }
}

private struct MacRow: View {
    let host: PairedHost

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(host.name)
                .font(.headline)
            Text(host.relay.host ?? host.relay.absoluteString)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Paired \(host.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// Task 3's stand-in for `TreeView`: just enough to prove a Mac row starts
/// a real `HostSession` and tracks its `phase` through connect / handshake /
/// ready, without pre-empting Task 4's actual tree UI.
private struct MacSessionPlaceholderView: View {
    @ObservedObject var model: AppModel
    let host: PairedHost

    var body: some View {
        VStack(spacing: 12) {
            if let session = model.session {
                Text(phaseDescription(session.phase))
                    .font(.title3)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .padding()
        .navigationTitle(host.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.startSession(for: host) }
        .onDisappear { model.stopSession() }
    }

    private func phaseDescription(_ phase: HostSession.Phase) -> String {
        switch phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting to \(host.name)…"
        case .handshaking: return "Verifying \(host.name)…"
        case .ready: return "Connected. (The session tree is coming in Task 4.)"
        case .attached(let paneId): return "Attached to \(paneId)."
        case .offline(let since):
            if let since { return "\(host.name) has been offline since \(since.formatted(date: .omitted, time: .shortened))." }
            return "\(host.name) is offline."
        case .failed(let reason): return "Could not connect: \(reason)"
        }
    }
}
