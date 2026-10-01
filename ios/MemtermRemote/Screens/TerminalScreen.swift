import SwiftUI
import MemtermRemoteApp

/// The live pane: SwiftTerm filling the safe area, with Back and Fit in the
/// toolbar. Fit is the ONLY control in this whole screen allowed to call
/// `session.resize` — see `TerminalViewHost`'s header comment for the full
/// rule and why it matters (a resize is visible, and can disturb a
/// full-screen program, on the Mac someone else may be sitting at).
struct TerminalScreen: View {
    @ObservedObject var session: HostSession
    let paneId: String
    /// Told apart from a person pressing Back: the Mac closed this pane out
    /// from under the viewer. `TreeView` uses it to show a brief notice
    /// rather than silently landing back where Back would also have landed.
    var onPaneClosedByHost: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var handle = TerminalViewHost.Handle()
    /// Set by the two ways the PERSON leaves this screen — the Back button and
    /// the swipe-back gesture — both of which detach and therefore land on
    /// `.ready`, exactly like the Mac closing the pane. Without it, whether
    /// `TreeView` showed "That pane was closed" after pressing Back depended
    /// on SwiftUI's update batching racing `dismiss()`, so the notice meant to
    /// distinguish those two cases appeared intermittently in the one case it
    /// exists to rule out.
    @State private var isLeavingOnPurpose = false

    var body: some View {
        TerminalViewHost(session: session, handle: handle)
            .ignoresSafeArea(edges: .bottom)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Back", action: back)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fit", action: fit)
                }
            }
            .safeAreaInset(edge: .top) { statusBanner }
            .onChange(of: session.phase) { _, phase in
                // The Mac closed this pane (it left the tree, or the session
                // simply returned to `.ready`): there is nothing left here to
                // show, so leave on its own rather than freezing on a dead
                // screen waiting for the person to notice and press Back.
                if case .ready = phase {
                    if !isLeavingOnPurpose { onPaneClosedByHost() }
                    dismiss()
                }
            }
            .onDisappear {
                // Covers the interactive swipe-back gesture, which bypasses
                // the Back button (and therefore `back()`) entirely. Guarded
                // on `.attached` so this never sends a second, redundant
                // detach after `back()` or the Mac-closed-it path above has
                // already moved the phase off `.attached`. The flag is set
                // BEFORE detaching, so the `.ready` that detach produces can
                // never be read as the Mac having closed the pane.
                if case .attached = session.phase {
                    isLeavingOnPurpose = true
                    session.detach()
                }
            }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch session.phase {
        case .offline(let since):
            StatusBanner(text: since.map {
                "This Mac has been offline since \($0.formatted(date: .omitted, time: .shortened))."
            } ?? "This Mac is offline.")
        case .unreachable:
            // The transport's own description is not shown: the person needs a
            // fact they can act on, and the kit is already retrying.
            StatusBanner(text: "Can't reach the relay. Still trying…")
        case .failed(let reason):
            StatusBanner(text: reason)
        case .idle, .connecting, .handshaking, .ready, .attached:
            EmptyView()
        }
    }

    private func back() {
        isLeavingOnPurpose = true
        if case .attached = session.phase { session.detach() }
        dismiss()
    }

    private func fit() {
        guard let dimensions = handle.proposeDimensions() else { return }
        session.resize(cols: dimensions.cols, rows: dimensions.rows)
    }
}

/// So a dead or offline Mac is visibly dead, not just a terminal that has
/// stopped updating — a phone's connection to the Mac failing mid-session
/// must never look the same as the Mac simply being quiet (task 4
/// self-review).
private struct StatusBanner: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(.orange.opacity(0.9), in: Rectangle())
            .foregroundStyle(.white)
    }
}
