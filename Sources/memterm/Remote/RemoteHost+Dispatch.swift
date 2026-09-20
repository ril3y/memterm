import AppKit
import Foundation
import MemtermCore

// Remote attach (decision doc 2026-09-19): the half of RemoteHost that knows
// about memterm's live model. Everything here runs on the MAIN thread —
// RemoteHost hops before calling in — because it reads the window/tab/pane
// graph and writes into SwiftTerm.
//
// Split out of RemoteHost.swift purely for size: the socket half is about
// bytes and keys, this half is about panes. Nothing here touches the wire.
//
// The doctrine the dispatcher enforces: a remote client can do exactly what a
// local keyboard can do to the same pane, and nothing else. Every case below
// ends in a call the local UI also makes — there is no side channel that
// bypasses the terminal, so the denylist and consent rules hold remotely by
// construction.

extension RemoteHost {

    /// Workspaces whose panes may not be attached. Always empty in this
    /// project: workspace locks are a separate follow-up, and the spec's
    /// `locked` field and refusal path exist here (and are exercised) so the
    /// protocol does not have to change when locks land.
    var lockedWorkspaceIds: Set<String> { [] }

    func dispatch(_ message: RemoteMessage, session: Session) {
        switch message {
        case .list:
            send(.tree(buildTree()), to: session.deviceId)

        case .attach(let paneId):
            attach(paneId: paneId, session: session)

        case .detach:
            detach(session: session)

        case .input(let bytes):
            guard let paneId = session.attachedPaneId else { return }
            streams[paneId]?.input(bytes)

        case .resize(let cols, let rows):
            guard let paneId = session.attachedPaneId, let stream = streams[paneId] else { return }
            // "Fit to me": the pty really does resize, and the answer reports
            // the size the grid ENDED UP at — SwiftTerm clamps, and a viewer
            // must never be told a size nothing is at.
            //
            // The wire's ints are clamped FIRST. A remote client may do what a
            // local keyboard can do and no more, and no local gesture can ask
            // for a grid of two billion columns — which `Terminal.resize`
            // would try to allocate and reflow.
            let safe = RemotePaneStream.clamp(cols: cols, rows: rows)
            let actual = stream.resize(cols: safe.cols, rows: safe.rows)
            send(.resized(cols: actual.cols, rows: actual.rows), to: session.deviceId)

        case .newTab(let workspaceId):
            newTab(workspaceId: workspaceId, session: session)

        case .unlock(let workspaceId, _):
            unlock(workspaceId: workspaceId, session: session)

        case .tree, .screen, .output, .treeChanged, .refused, .resized:
            // Host→client messages. A client sending one is confused or
            // hostile; either way there is nothing to do with it.
            break
        }
    }

    // MARK: - Tree

    /// The same tree the timeline lists: workspaces → windows → tabs → panes.
    ///
    /// Windows come from the live hosts rather than the journal, because a
    /// remote viewer is attaching to what is RUNNING, not to what was saved.
    /// A window is named by its first tab's id — the journal's own convention
    /// — so the id is stable for as long as that window has tabs.
    func buildTree() -> RemoteTree {
        let workspaces = app.memory?.store.listWorkspaces() ?? []
        return RemoteTree(workspaces: workspaces.map { workspace in
            let windows = app.hosts
                .filter { $0.workspaceId == workspace.id }
                .compactMap { host -> RemoteWindow? in
                    guard let windowId = host.tabs.first?.tabId else { return nil }
                    return RemoteWindow(id: windowId, tabs: host.tabs.map { tab in
                        RemoteTab(id: tab.tabId, title: tab.displayTitle,
                                  panes: tab.allPanes().map(Self.remotePane))
                    })
                }
            return RemoteWorkspace(
                id: workspace.id,
                name: workspace.name,
                color: workspace.color,
                locked: lockedWorkspaceIds.contains(workspace.id),
                parked: workspace.isParked,
                windows: windows)
        })
    }

    private static func remotePane(_ pane: PaneView) -> RemotePane {
        // The adapter kind tells a client what it is looking at; serial panes
        // are listed honestly even though they cannot be attached yet.
        RemotePane(id: pane.paneId,
                   adapter: pane is SerialPaneView ? "serial" : "shell",
                   cwd: pane.lastKnownCwd)
    }

    // MARK: - Attach / detach

    private func attach(paneId: String, session: Session) {
        guard let pane = app.controllers.flatMap({ $0.allPanes() })
            .first(where: { $0.paneId == paneId })
        else {
            send(.refused(reason: "unknown-pane"), to: session.deviceId)
            return
        }
        // Locks are a later project; the branch exists so the wire contract
        // (and the client's handling of it) is settled now.
        if let workspaceId = workspaceId(ofPane: paneId), lockedWorkspaceIds.contains(workspaceId) {
            send(.refused(reason: "locked"), to: session.deviceId)
            return
        }
        // A serial pane's bytes come from the IOKit reader, not the pty taps
        // RemotePaneStream listens on, so attaching one would show a viewer a
        // frozen screen. Refusing is the honest answer.
        if pane is SerialPaneView {
            send(.refused(reason: "unsupported"), to: session.deviceId)
            return
        }

        // One pane at a time per device: attaching elsewhere detaches first.
        detach(session: session)

        let stream = streams[paneId] ?? RemotePaneStream(pane: pane)
        streams[paneId] = stream
        session.attachedPaneId = paneId
        // addViewer sends the current screen, then every chunk. The closure
        // is the ONLY thing that keeps this viewer alive, so it must not
        // retain the host: a dropped session must be able to free it.
        stream.addViewer(session.deviceId) { [weak self] message in
            self?.send(message, to: session.deviceId)
        }
    }

    private func detach(session: Session) {
        guard let paneId = session.attachedPaneId else { return }
        removeViewer(session.deviceId, from: paneId)
        session.attachedPaneId = nil
    }

    /// Drops one viewer and, when it was the last, the stream itself — which
    /// is what removes the pane's output tap, so an unwatched pane pays
    /// nothing per chunk.
    func removeViewer(_ deviceId: String, from paneId: String) {
        guard let stream = streams[paneId] else { return }
        stream.removeViewer(deviceId)
        if stream.viewerCount == 0 { streams[paneId] = nil }
    }

    /// Forgets streams whose pane is gone (its tab was closed locally) and
    /// clears the viewers that were watching it. Without this, closing a tab
    /// under an attached phone would leave the host holding the dead pane and
    /// the device believing it is still attached; the client learns the truth
    /// from the `tree-changed` that follows.
    func pruneClosedPanes() {
        guard !streams.isEmpty else { return }
        let live = Set(app.controllers.flatMap { $0.allPanes() }.map(\.paneId))
        for paneId in Array(streams.keys) where !live.contains(paneId) {
            streams[paneId] = nil
        }
        for session in sessions.values {
            if let paneId = session.attachedPaneId, !live.contains(paneId) {
                session.attachedPaneId = nil
            }
        }
    }

    private func workspaceId(ofPane paneId: String) -> String? {
        app.controllers
            .first { $0.allPanes().contains { $0.paneId == paneId } }?
            .workspaceId
    }

    // MARK: - New tab

    /// A plain shell tab in the named workspace — the same thing ⌘T does, and
    /// never a command: a remote client may open a terminal, not run one.
    ///
    /// This mirrors `ExtensionHost.openTab`: join the workspace's existing
    /// non-dropdown host, or give a workspace with no window a fresh host,
    /// and never yank the user to another workspace.
    private func newTab(workspaceId: String, session: Session) {
        guard app.memory?.store.listWorkspaces().contains(where: { $0.id == workspaceId }) == true
        else {
            send(.refused(reason: "unknown-workspace"), to: session.deviceId)
            return
        }
        if lockedWorkspaceIds.contains(workspaceId) {
            send(.refused(reason: "locked"), to: session.deviceId)
            return
        }
        let controller = TerminalWindowController(app: app, workspaceId: workspaceId,
                                                  initialCwd: nil)
        app.registerController(controller)
        let isActive = workspaceId == app.activeWorkspaceId
        if let host = app.hosts.first(where: { $0.workspaceId == workspaceId && !$0.isDropdown }) {
            host.attach(controller, select: isActive)
        } else {
            let fresh = app.makeHost(frame: nil)
            fresh.attach(controller, select: true)
            // Not the active workspace: the fresh host stays a hidden holder
            // that FR-59's switch machinery presents later.
            if isActive { fresh.showWindow(nil) }
        }
        app.materializedWorkspaceIds.insert(workspaceId)
        app.memory?.scheduleTopologySave()
        // refreshWorkspaceChips broadcasts tree-changed to every session,
        // including this one — the client re-lists and finds the new tab.
        app.refreshWorkspaceChips()
    }

    // MARK: - Unlock (hook)

    /// No workspace is lockable yet, so the honest answer is always a
    /// refusal. The rate limiter still runs, and still comes first: the whole
    /// point is that a device cannot learn anything by asking repeatedly, and
    /// that property has to hold from the day the protocol exists.
    private func unlock(workspaceId: String, session: Session) {
        guard unlockLimiter.allow(deviceId: session.deviceId,
                                  at: Date().timeIntervalSince1970)
        else {
            send(.refused(reason: "rate-limited"), to: session.deviceId)
            return
        }
        send(.refused(reason: "locked"), to: session.deviceId)
    }
}
