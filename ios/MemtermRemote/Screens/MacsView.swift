import SwiftUI
import MemtermRemoteApp

/// The app's home screen: every Mac this device has been allowed into.
/// Tapping a row starts that Mac's `HostSession` and pushes `TreeView`.
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
                        // The one thing this app can detect but not fix: the
                        // identity key every Mac below was paired against is
                        // gone, so they will all refuse this device until it is
                        // paired again. Without this the person sees only
                        // handshakes that fail for no stated reason.
                        if let notice = model.identityNotice {
                            Section {
                                Label(notice, systemImage: "key.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(model.hosts) { host in
                            NavigationLink {
                                MacSessionHost(model: model, host: host)
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

/// Starts (and tears down) `host`'s one live `HostSession` for exactly as
/// long as its tree is on screen, and hands that session to the real
/// `TreeView` once it exists. Connecting/handshaking show a spinner rather
/// than an empty tree — `TreeView` itself only has something to group once
/// `session.tree` has arrived.
private struct MacSessionHost: View {
    @ObservedObject var model: AppModel
    let host: PairedHost

    var body: some View {
        Group {
            if let session = model.session {
                TreeView(session: session, host: host)
            } else {
                ProgressView()
                    .navigationTitle(host.name)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear { model.startSession(for: host) }
        .onDisappear { model.stopSession() }
    }
}
