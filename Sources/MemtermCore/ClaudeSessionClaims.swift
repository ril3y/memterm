import Foundation

// FR-36 / §9 invariant: "the same Claude session UUID is never offered on two
// panes." The capture side's projects-dir fallback resolves newest-mtime per
// cwd, so two claude panes sharing a cwd persist the same sessionId — this
// registry dedupes at offer time: the first pane to claim a UUID gets
// `claude --resume <uuid>`, every other pane downgrades to `claude --continue`
// (honestly labeled "most recent session in this directory"). Claims are
// released when a pane closes, so a workspace reopened later can re-offer.
//
// Main-thread only (restore and pane-close paths both run there).

public final class ClaudeSessionClaims {
    private var owners: [String: String] = [:]  // sessionId -> paneId

    public init() {}

    /// True if `paneId` now owns (or already owned) the session id — the
    /// caller may offer `--resume <sessionId>`. False means another live pane
    /// holds it: downgrade this pane's offer.
    public func claim(sessionId: String, paneId: String) -> Bool {
        if let owner = owners[sessionId] { return owner == paneId }
        owners[sessionId] = paneId
        return true
    }

    /// Releases every claim held by a closing pane.
    public func release(paneId: String) {
        owners = owners.filter { $0.value != paneId }
    }

    public func owner(of sessionId: String) -> String? {
        owners[sessionId]
    }
}
