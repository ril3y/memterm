import Foundation

// Serial link lifecycle (feature/serial disconnect/connect stage). Pure core
// per the TESTING.md placement rule: the pane keeps ONE machine instance and
// derives every flag from it; the machine owns the transition rules, most
// importantly the founder invariant that a DELIBERATE release must never be
// undone behind the user's back.
//
// The founder scenario this exists for: "opened it at the wrong baud but no
// way to close it and reopen with the right baud" — plus the deeper embedded
// need to RELEASE the port so esptool/avrdude can flash, then reconnect,
// without losing the pane or its scrollback. While esptool holds the device
// it disappears and reappears from IOKit's point of view; if a user-released
// pane still auto-reopened on hotplug return it would steal the port back
// mid-flash. Hence the two distinct not-connected-anymore states:
//
//   connected ──deviceLost()──────▶ reconnectingAfterLoss   (auto-reopen ARMED)
//   connected ──userDisconnect()──▶ userDisconnected        (auto-reopen SUPPRESSED)
//
// `idle` is the pre-consent state (a restored pane waiting on the ⌘R offer,
// or a failed first open): not connected, no standing consent, so hotplug
// never auto-opens there either — the consent story is unchanged.
public struct SerialLinkStateMachine: Equatable {

    public enum State: Equatable {
        /// Never connected this session (restored offer pending / failed
        /// first open). Connect requires the explicit gesture.
        case idle
        /// The fd is open and pumping.
        case connected
        /// Device vanished under a LIVE session: the user's original open is
        /// standing consent, so hotplug return auto-reopens (tio-style).
        case reconnectingAfterLoss
        /// The USER closed the port on purpose (release for flashing, wrong
        /// baud, …). Hotplug auto-reopen is suppressed: only an explicit
        /// connect gesture reopens, with the CURRENT (possibly edited)
        /// settings.
        case userDisconnected
    }

    public private(set) var state: State

    public init(initial: State = .idle) {
        state = initial
    }

    // MARK: - Events

    /// An open(2) succeeded (first connect, reconnect gesture, hotplug
    /// return — every path funnels through the pane's one connect()).
    public mutating func didConnect() {
        state = .connected
    }

    /// The deliberate user release. Meaningful from `connected` (close the
    /// fd) and from `reconnectingAfterLoss` (stop waiting — cancel the
    /// armed auto-reopen); a no-op elsewhere: there is nothing to release,
    /// and `idle`'s consent posture must not be relabeled.
    public mutating func userDisconnect() {
        guard state == .connected || state == .reconnectingAfterLoss else { return }
        state = .userDisconnected
    }

    /// EOF / revoked fd / IOKit detach under a live session. Only a
    /// CONNECTED session arms the auto-reopen; a loss reported after a user
    /// disconnect (drivers can race the close) must not re-arm it.
    public mutating func deviceLost() {
        guard state == .connected else { return }
        state = .reconnectingAfterLoss
    }

    // MARK: - Queries (the pane derives all its flags from these)

    public var isConnected: Bool { state == .connected }

    /// The hotplug gate: ONLY a device-vanished loss keeps the standing
    /// consent that allows an automatic reopen on device return.
    public var shouldAutoReopenOnHotplug: Bool { state == .reconnectingAfterLoss }

    /// Whether an explicit connect gesture makes sense right now.
    public var allowsConnectGesture: Bool { state != .connected }
}
