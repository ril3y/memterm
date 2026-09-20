import Foundation
import MemtermCore

// Remote attach (decision doc 2026-09-19), Task 8: the object that turns ONE
// live pane into a stream a remote viewer can follow, and turns a remote
// viewer's keystrokes back into pty input. Task 9's host owns one of these per
// attached pane and does the framing/transport; this type knows only about
// `PaneView` and `RemoteMessage`.
//
// What a viewer sees is exactly what the pty printed: `addViewer` sends the
// current screen once, then every output chunk as it arrives. What a viewer
// types goes down `PaneView.remoteInput`, which is the same `send(data:)` path
// the local keyboard uses — a remote client can do nothing a local one can't.
//
// THREADING: main-thread only, all of it. PaneView's taps fire on the main
// thread (LocalProcess delivers pty data there) and SwiftTerm's `send(data:)`
// asserts the main thread in DEBUG, so a host reading a socket on its own
// queue must hop to main before calling `input` or `resize`.
final class RemotePaneStream {

    /// One attached client. A class so the tap's fan-out can mutate the
    /// backlog in place without copying it back into the dictionary.
    private final class Viewer {
        let send: (RemoteMessage) -> Void
        var backlog: OutputBacklog

        init(send: @escaping (RemoteMessage) -> Void, backlogLimit: Int) {
            self.send = send
            self.backlog = OutputBacklog(limit: backlogLimit)
        }
    }

    private let pane: PaneView
    private let backlogLimit: Int
    private var viewers: [String: Viewer] = [:]
    /// The pane tap token, held only while at least one viewer is attached.
    private var tapId: UUID?

    init(pane: PaneView, backlogLimit: Int = 262_144) {
        self.pane = pane
        self.backlogLimit = backlogLimit
    }

    deinit {
        guard let tapId else { return }
        // The pane outlives the stream, so a tap left behind would keep firing
        // into a dead weak reference forever. Removing it is main-thread work;
        // deinit can land anywhere.
        let pane = self.pane
        if Thread.isMainThread {
            pane.removeOutputTap(tapId)
        } else {
            DispatchQueue.main.async { pane.removeOutputTap(tapId) }
        }
    }

    // MARK: - Viewers

    var viewerCount: Int { viewers.count }

    /// Attaches a viewer: it is sent the current screen immediately, then every
    /// subsequent pty chunk as `.output`.
    ///
    /// The screen goes out BEFORE the tap is installed, which on the main
    /// thread means no chunk can slip between the snapshot and the first
    /// forwarded byte — the viewer's first frame is the local pane's frame.
    func addViewer(_ id: String, send: @escaping (RemoteMessage) -> Void) {
        viewers[id] = Viewer(send: send, backlogLimit: backlogLimit)
        let screen = pane.visibleScreenBytes()
        send(.screen(cols: screen.cols, rows: screen.rows, bytes: screen.bytes))
        installTapIfNeeded()
    }

    /// Detaches a viewer, dropping its backlog. The pane tap is removed when
    /// the last viewer leaves, so an unattached pane pays nothing per chunk.
    func removeViewer(_ id: String) {
        viewers.removeValue(forKey: id)
        guard viewers.isEmpty, let tapId else { return }
        pane.removeOutputTap(tapId)
        self.tapId = nil
    }

    /// Bytes this viewer will never see, because a burst overran its backlog.
    /// Probe surface (Task 12) and a host-side health signal.
    func droppedBytes(for viewerId: String) -> Int {
        viewers[viewerId]?.backlog.droppedBytes ?? 0
    }

    private func installTapIfNeeded() {
        guard tapId == nil else { return }
        tapId = pane.addOutputTap { [weak self] chunk in
            self?.fanOut(chunk)
        }
    }

    /// v1 back-pressure: `send` is synchronous over the host's socket queue, so
    /// the backlog is a coalescing buffer rather than a queue that outlives the
    /// call — append, drain, send, once per chunk. It still enforces the cap:
    /// a chunk bigger than the limit is kept whole (it is the newest data),
    /// and anything evicted is counted in `droppedBytes`.
    private func fanOut(_ chunk: Data) {
        // Snapshot the values: a `send` that detaches its own viewer mid-chunk
        // must not invalidate the walk.
        for viewer in Array(viewers.values) {
            viewer.backlog.append(chunk)
            let pending = viewer.backlog.drain()
            guard !pending.isEmpty else { continue }
            viewer.send(.output(pending))
        }
    }

    // MARK: - Remote → pane

    /// Remote keystrokes into the pty, via the pane's keyboard path.
    func input(_ bytes: Data) {
        pane.remoteInput(bytes)
    }

    /// Resizes the emulator grid and the pty window, and reports the size the
    /// pane actually ended up at so the host can answer `.resized`.
    ///
    /// Deliberately NOT `TerminalView.resize(cols:rows:)`: that packaged call
    /// ends in `terminal.softReset()` (AppleTerminalView.swift:2838-2843),
    /// which clears application keypad/cursor mode, origin and insert mode,
    /// the charset and the scroll region — a remote resize would break the
    /// arrow keys under a running vim or htop, which dragging the local window
    /// never does. The frame-driven local path resizes the emulator with no
    /// such reset, so this takes the same two steps by hand:
    ///
    /// 1. `Terminal.resize(cols:rows:)` (Terminal.swift:6740) — reflows the
    ///    grid, clamping to SwiftTerm's minimum and returning early when the
    ///    size is unchanged. No reset.
    /// 2. `LocalProcessTerminalView.sizeChanged` (MacLocalTerminalView.swift:104)
    ///    — sets the pty winsize, which `getWindowSize()` reads back off
    ///    `terminal.cols/rows`, so step 1 must come first. The delegate is
    ///    notified with the grid's ACTUAL size, not the requested one, so a
    ///    clamped request doesn't announce a size nothing is at.
    ///
    /// The view's own grid stays frame-derived: the local window's next layout
    /// pass may recompute cols/rows from the pane's frame and overwrite this.
    /// That is the spec's "host window wins" rule — the returned pair is the
    /// truth at this moment, not a promise about the next one.
    @discardableResult
    func resize(cols: Int, rows: Int) -> (cols: Int, rows: Int) {
        let terminal = pane.getTerminal()
        guard cols > 0, rows > 0 else { return (terminal.cols, terminal.rows) }
        terminal.resize(cols: cols, rows: rows)
        pane.sizeChanged(source: pane, newCols: terminal.cols, newRows: terminal.rows)
        return (terminal.cols, terminal.rows)
    }
}
