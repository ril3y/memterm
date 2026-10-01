import CryptoKit
import Foundation
import MemtermRemoteKit

/// One paired Mac, while the app is in the foreground and that Mac is on
/// screen. Owns the relay connection, the handshake, the session keys and
/// the attached pane.
///
/// Main-actor throughout: `RelayConnection` requires main-queue calls, and
/// `RemoteSessionKeys`' counters must be consumed in order — doing both on
/// one actor is what makes "records go out in the order they were sealed"
/// true by construction rather than by care.
///
/// `CryptoKit` import note: `signer` is a `RemoteSigner`, not a concrete
/// `RemoteIdentity` (that is the whole point — a phone's signer is a Secure
/// Enclave key, which has no `RemoteIdentity` representation). The kit's
/// `RemoteHandshake.makeHello(signer:)` takes a `RemoteSigner` for exactly
/// this reason, so this type does not build its own Hello — but
/// `RemoteHandshake.deriveKeys(myEphemeral:…)`'s first parameter is a raw
/// CryptoKit key type, so holding the ephemeral between sending our Hello
/// and the Mac's reply still requires this import. See
/// `scripts/check-extension-firewall.sh`'s `remote-app` line.
@MainActor
public final class HostSession: ObservableObject {
    public enum Phase: Equatable {
        case idle, connecting, handshaking, ready
        case attached(paneId: String)
        /// The relay was reached, and either it says this Mac is away or the
        /// Mac never answered our Hello. `since` is the relay's `lastSeen`,
        /// when it gave a plausible one.
        case offline(since: Date?)
        /// The relay itself could not be reached: no network, a relay that is
        /// down, a wrong URL. Kept separate from `.offline` because "I can't
        /// reach the relay" and "your Mac is away" are different facts a
        /// person acts on differently — one is about the phone in their hand,
        /// the other about a Mac somewhere else. The payload is the
        /// transport's own description, for diagnosis; what the person reads
        /// is a sentence, not this. `RelayConnection` is already retrying
        /// with backoff whenever this is set, so it is a status, not an end.
        case unreachable(String?)
        /// Reserved for a session that genuinely cannot continue. A refusal
        /// the Mac sends for one request is NOT this — see `handleRefusal`.
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var tree: RemoteTree?
    /// One sentence about the last thing that did not work, for the cases
    /// where that thing did not end the session — a workspace that is locked,
    /// a pane this app cannot attach to. Cleared by anything that supersedes
    /// it: a restart, a teardown, or the next attach.
    @Published public private(set) var notice: String?
    /// Screen bytes then output chunks for the attached pane, newest last.
    public var onOutput: ((Data) -> Void)?

    /// How long a Hello may go unanswered before the Mac is reported as away.
    /// The relay has already authenticated us by that point, so the thing not
    /// answering is the Mac, not the relay.
    public static let handshakeTimeout: TimeInterval = 20
    /// The relay's `online` hint can arrive as often as the relay likes, and
    /// every restart it causes makes the Mac run `endSession`. At most one
    /// restart per this interval.
    public static let onlineRestartInterval: TimeInterval = 5
    /// How long a liveness probe's `.list` may go unanswered before this
    /// session concludes the Mac is not the one it is still holding keys with
    /// and restarts. Shorter than `handshakeTimeout` on purpose: by the time a
    /// probe is sent, the relay has authenticated us AND a handshake has
    /// already completed, so the Mac has demonstrably answered quickly once
    /// already. It is also a distinct value so a test can name which timer it
    /// means.
    public static let livenessProbeTimeout: TimeInterval = 10
    /// `pendingHandshakes` is fed by a relay-sent frame (`authed`), so it
    /// needs a ceiling. Reaching it restarts the session rather than trimming
    /// the queue — see `beginHandshake`, which explains why dropping entries
    /// is not a safe way to bound this.
    static let maxPendingHandshakes = 8
    /// Bounds on a `lastSeen` this app is willing to put in a sentence.
    static let lastSeenFutureSlack: TimeInterval = 60 * 60
    static let lastSeenMaxAge: TimeInterval = 60 * 60 * 24 * 365

    private let host: PairedHost
    private let signer: RemoteSigner
    private let makeConnection: (URL, RelayConnection.Events) -> RelayConnection
    private let schedule: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    private let now: () -> Date
    private var connection: RelayConnection?
    private var keys: RemoteSessionKeys?

    /// Handshakes sent but not yet answered, oldest first. A reconnect can
    /// fire "authed" a second time with no `start()` in between — the relay
    /// re-authenticating us under us — so more than one Hello can be
    /// genuinely in flight at once, each with its own ephemeral. The Mac
    /// answers each Hello it receives exactly once, in the order it received
    /// them, so a reply is matched to the OLDEST still-outstanding entry
    /// (`removeFirst()`), never to whatever is merely "current" — pairing a
    /// stale reply with a newer ephemeral would silently derive keys neither
    /// side actually holds, which is worse than dropping it. `generation`
    /// then decides whether that correctly-paired entry is still the live
    /// attempt or one a later `start()`/"authed" has since superseded.
    private var pendingHandshakes: [(ephemeral: P256.KeyAgreement.PrivateKey, generation: Int)] = []
    private var handshakeGeneration = 0
    private var handshakeTimeoutWork: DispatchWorkItem?
    private var livenessProbeWork: DispatchWorkItem?
    private var lastOnlineAction: Date?

    private var attachedPaneId: String?
    /// Survives a background/foreground cycle so the viewer comes back to
    /// the pane it was on, when that pane still exists.
    private var lastAttachedPaneId: String?

    /// The Mac's peer id, derived fresh from the pinned SPKI every time —
    /// never taken from `host.id` as a shortcut, so there is exactly one
    /// place this binding can go wrong, and it is this one.
    private var hostId: String { RemoteIdentity.peerId(forSPKI: host.publicKeySPKI) }

    /// - Parameters:
    ///   - schedule: How the handshake timeout is armed. Defaults to the main
    ///     queue; a test injects a manual scheduler so the timeout can be
    ///     fired on demand rather than waited out.
    ///   - now: The clock the `online` throttle and the `lastSeen` sanity
    ///     bound read. Injectable for the same reason.
    public init(host: PairedHost, signer: RemoteSigner,
                makeConnection: @escaping (URL, RelayConnection.Events) -> RelayConnection,
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
                    = RelayConnection.mainQueueSchedule,
                now: @escaping () -> Date = Date.init) {
        self.host = host; self.signer = signer; self.makeConnection = makeConnection
        self.schedule = schedule; self.now = now
    }

    // MARK: - Lifecycle

    public func start() {
        handshakeGeneration += 1
        connection?.stop()
        keys = nil
        pendingHandshakes.removeAll()
        cancelHandshakeTimeout()
        cancelLivenessProbe()
        attachedPaneId = nil
        notice = nil
        phase = .connecting

        var events = RelayConnection.Events()
        // Transport death is reported HERE and nowhere else. Without this,
        // an unreachable relay left `phase` at `.connecting` forever while
        // the kit reconnected silently behind it — on screen, an eternal
        // spinner for the one condition the person could actually act on.
        events.onState = { [weak self] state in self?.handleState(state) }
        events.onControl = { [weak self] object in self?.handleControl(object) }
        events.onEnvelope = { [weak self] envelope in self?.handleEnvelope(envelope) }
        let conn = makeConnection(host.relay, events)
        connection = conn
        conn.start()
    }

    public func stop() {
        connection?.stop()
        connection = nil
        keys = nil
        pendingHandshakes.removeAll()
        cancelHandshakeTimeout()
        cancelLivenessProbe()
        attachedPaneId = nil
        // A tree kept across a teardown is a tree that gets rendered again on
        // the way back in, before any fresh data has arrived — panes that may
        // have closed while the app was away, shown as though they were live.
        tree = nil
        notice = nil
        phase = .idle
    }

    public func sceneBecameActive() { start() }
    public func sceneWentToBackground() { stop() }

    // MARK: - Viewer actions

    /// Sets `.attached` optimistically, before the Mac's `.screen` reply
    /// arrives: the screen is one round trip away, and a viewer should not
    /// stall on a blank state waiting for it. A pane id that turns out to be
    /// wrong is corrected by the `refused` that follows — `handleRefusal`
    /// turns that into a readable return to the tree, so it really is
    /// corrected and not merely reported. Do not "fix" this into waiting for
    /// `.screen` first.
    public func attach(paneId: String) {
        notice = nil
        attachedPaneId = paneId
        lastAttachedPaneId = paneId
        phase = .attached(paneId: paneId)
        send(.attach(paneId: paneId))
    }

    public func detach() {
        attachedPaneId = nil
        lastAttachedPaneId = nil
        phase = .ready
        send(.detach)
    }

    public func input(_ bytes: Data) {
        send(.input(bytes))
    }

    public func resize(cols: Int, rows: Int) {
        send(.resize(cols: cols, rows: rows))
    }

    // MARK: - Transport state

    private func handleState(_ state: RelayConnection.State) {
        // `.failed` is the one terminal phase, so nothing the transport does
        // afterwards may overwrite the reason standing there — a revoked
        // device must keep reading "this Mac no longer allows this device",
        // not turn into a network complaint when the socket then closes.
        if case .failed = phase { return }
        switch state {
        case .offline(let reason):
            // The kit is already retrying with 1 s → 30 s backoff, so this is
            // the status of that, not the end of the session.
            cancelHandshakeTimeout()
            phase = .unreachable(reason)
        case .connecting:
            phase = .connecting
        case .connected, .off:
            // `authed` drives the handshake from `handleControl`, and
            // `stop()` sets `.idle` itself — including for the `.off` that
            // `connection?.stop()` emits from inside `start()`.
            break
        }
    }

    // MARK: - Relay control frames

    private func handleControl(_ object: [String: Any]) {
        guard let type = object["type"] as? String else { return }
        switch type {
        case "authed":
            beginHandshake()
        case "offline":
            guard isAboutThisHost(object) else { return }
            phase = .offline(since: plausibleDate(fromEpochMilliseconds: object["lastSeen"] as? Double))
        case "online":
            guard isAboutThisHost(object), !isThrottled() else { return }
            switch phase {
            case .offline, .unreachable:
                // Nothing to lose: there is no session worth protecting.
                lastOnlineAction = now()
                start()
            case .ready, .attached:
                lastOnlineAction = now()
                probeLiveness()
            case .idle, .connecting, .handshaking, .failed:
                // `.idle` is a stopped session, `.failed` is a verdict this
                // frame cannot overturn, and the middle two are already on
                // their way with their own timeout armed.
                break
            }
        case "refused":
            let reason = object["reason"] as? String ?? ""
            if reason == "not-allowed" {
                phase = .failed("This Mac no longer allows this device.")
            } else {
                // Every other reason here is a relay-chosen string, and the
                // relay is hostile by assumption: it is never put on screen
                // verbatim. The one thing it can honestly mean is that the
                // relay will not connect this device to that Mac.
                phase = .failed("The relay would not connect this device to \(host.name).")
            }
        default:
            break
        }
    }

    /// `offline` and `online` each name the host they are about
    /// (`relay/src/server.ts`), and a frame about some other Mac must not
    /// move this session's phase. A frame with no `hostId` at all is not one
    /// this app can attribute, so it is ignored too.
    private func isAboutThisHost(_ object: [String: Any]) -> Bool {
        (object["hostId"] as? String) == hostId
    }

    /// `online` is a hint from an untrusted party, not a command, so no path
    /// out of it may be unbounded: at most one action per
    /// `onlineRestartInterval`, whichever action it is.
    private func isThrottled() -> Bool {
        guard let lastOnlineAction else { return false }
        return now().timeIntervalSince(lastOnlineAction) < Self.onlineRestartInterval
    }

    /// An `online` frame while this session believes it is working is the one
    /// case that needs care, and the first version of this gate got it wrong
    /// by ignoring the frame outright.
    ///
    /// Restarting unconditionally was the original bug: every `start()` closes
    /// the socket and makes the Mac run `endSession`, dropping its viewer
    /// attach, so a relay could churn a healthy session at will. But ignoring
    /// the frame drops a recovery that used to work. The relay sends `online`
    /// with no preceding `offline` when a host re-authenticates — it closes
    /// the previous socket with 4005 "replaced", and that socket's own close
    /// handler returns early precisely so no `offline` goes out
    /// (`relay/src/server.ts`). If the Mac died ungracefully and relaunched
    /// before the heartbeat reaped its stale socket, the Mac's in-memory
    /// session for this device is gone, these keys are dead, and the only
    /// frame this session will ever receive about it is that `online`. The
    /// Mac silently drops records from a device it no longer has a session
    /// for, and no timeout covers `.ready` or `.attached` — so the person sits
    /// watching a terminal that has quietly stopped. That silent stall is the
    /// exact defect class this app has already shipped once and been bitten
    /// by.
    ///
    /// So treat the frame as neither: probe. Ask for the tree, which any live
    /// Mac answers in milliseconds, and let the absence of an answer be the
    /// evidence. A `.tree` cancels the timer and costs one small message;
    /// silence restarts. A hostile relay gains nothing it did not already
    /// have — it can drop frames whenever it likes — and a working session is
    /// never torn down on a stranger's say-so.
    private func probeLiveness() {
        cancelLivenessProbe()
        send(.list)
        livenessProbeWork = schedule(Self.livenessProbeTimeout) { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .ready, .attached:
                // Still no tree. The keys this session holds are for a
                // session the Mac no longer has.
                self.start()
            case .idle, .connecting, .handshaking, .offline, .unreachable, .failed:
                // Something already moved this session on; the probe's
                // question is moot.
                break
            }
        }
    }

    private func cancelLivenessProbe() {
        livenessProbeWork?.cancel()
        livenessProbeWork = nil
    }

    /// A `lastSeen` is formatted straight into a sentence the person reads,
    /// and it comes from the relay — so an implausible one is dropped rather
    /// than printed. Falling back to `nil` costs only the time in that
    /// sentence.
    private func plausibleDate(fromEpochMilliseconds milliseconds: Double?) -> Date? {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        let reference = now()
        guard date <= reference.addingTimeInterval(Self.lastSeenFutureSlack),
              date >= reference.addingTimeInterval(-Self.lastSeenMaxAge)
        else { return nil }
        return date
    }

    /// The phone speaks first: a fresh ephemeral, signed by whatever signer
    /// we were given, sent in the clear (there is no key yet) inside an
    /// envelope. `RemoteHandshake.makeHello(signer:)` and `HelloWire` are the
    /// kit's shared implementations — the same ones the Mac host and the
    /// headless probe client use — so there is exactly one wire format.
    private func beginHandshake() {
        // The cap is reached only when the relay has sent more `authed` frames
        // than the Mac has sent replies, so bound it by resetting, not by
        // trimming.
        //
        // Trimming looked safe and was not. Replies carry no request id, so
        // `removeFirst()` IS the correlation: the Mac answers each Hello once,
        // in order. Dropping from the front shifts every later reply onto the
        // wrong entry, so the live reply pops a stale entry, fails the
        // generation check, and is discarded — the handshake that would have
        // succeeded is thrown away, and the session waits out its timeout
        // instead. (The generation check keeps that merely wasteful rather
        // than dangerous: a mismatched pairing is refused, never used to
        // derive keys. It is still the wrong outcome.)
        //
        // `start()` clears the queue and the socket together, which keeps the
        // positional invariant intact instead of quietly breaking it.
        if pendingHandshakes.count >= Self.maxPendingHandshakes {
            start()
            return
        }
        handshakeGeneration += 1
        let generation = handshakeGeneration
        guard let (hello, ephemeral) = try? RemoteHandshake.makeHello(signer: signer) else {
            phase = .failed("Could not sign the handshake.")
            return
        }
        pendingHandshakes.append((ephemeral: ephemeral, generation: generation))
        phase = .handshaking
        armHandshakeTimeout(generation: generation)

        let envelope = RemoteEnvelope(to: hostId, from: signer.id, payload: HelloWire.encode(hello))
        connection?.send(envelope: envelope, completion: nil)
    }

    /// A Hello the Mac never answers used to leave `.handshaking` standing
    /// indefinitely — the relay has no reason to tell us about that, so
    /// nothing else would ever move the phase. We are past `authed` here, so
    /// the relay is demonstrably fine and the Mac is the thing not answering:
    /// that is the same fact the relay's own `offline` frame reports, minus a
    /// last-seen time.
    private func armHandshakeTimeout(generation: Int) {
        handshakeTimeoutWork?.cancel()
        handshakeTimeoutWork = schedule(Self.handshakeTimeout) { [weak self] in
            guard let self, generation == self.handshakeGeneration else { return }
            guard case .handshaking = self.phase else { return }
            self.phase = .offline(since: nil)
        }
    }

    private func cancelHandshakeTimeout() {
        handshakeTimeoutWork?.cancel()
        handshakeTimeoutWork = nil
    }

    // MARK: - Envelopes

    private func handleEnvelope(_ envelope: RemoteEnvelope) {
        guard envelope.from == hostId else { return }

        if let hello = HelloWire.decode(envelope.payload) {
            // Verified BEFORE the queue is touched. The relay chooses
            // `envelope.from`, so it can inject a Hello claiming to be the
            // Mac; popping first spent the live ephemeral on that forgery,
            // dropped the Mac's genuine reply against an empty queue, and
            // told the person their MAC's identity could not be verified — a
            // security claim about the wrong party. Verification needs only
            // the Hello and the pinned SPKI, so an unverifiable one is
            // discarded with no state change at all, and the genuine reply
            // still completes the handshake.
            guard RemoteHandshake.verifyHello(hello, peerSPKI: host.publicKeySPKI) else {
                NSLog("memterm: ignored a Hello for \(hostId) that this Mac's key did not sign")
                return
            }
            // The Mac's half of the handshake, in the clear, answered in the
            // order the Hellos were sent — so the oldest still-outstanding
            // entry is the one THIS reply pairs with, never whichever
            // ephemeral merely happens to be current. Popping is itself the
            // correlation: there is no request id on the wire to match
            // against, only send order.
            guard !pendingHandshakes.isEmpty else { return }
            let (ephemeral, generation) = pendingHandshakes.removeFirst()
            // The correctly-paired entry may still belong to an attempt a
            // later `start()`/"authed" has since superseded — that reply
            // must not win a race against the live handshake's keys.
            guard generation == handshakeGeneration else { return }
            guard let derived = try? RemoteHandshake.deriveKeys(
                myEphemeral: ephemeral,
                peerEphemeralRaw: hello.ephemeralRaw,
                hostId: hostId,
                deviceId: signer.id,
                iAmHost: false)
            else {
                phase = .failed("Could not complete the handshake.")
                return
            }
            keys = derived
            cancelHandshakeTimeout()
            send(.list)
            return
        }

        guard let keys else { return }
        let plaintext: Data
        do {
            plaintext = try keys.open(envelope.payload)
        } catch {
            // A record that will not open cannot have come from the paired
            // Mac: it would have to be sealed under keys only this device and
            // that Mac hold, and the relay holds neither. So it is someone
            // else's noise, and the right answer is to ignore it — the kit
            // deliberately does not advance the receive counter on a failed
            // open ("so the genuine next record still opens afterwards",
            // `RemoteCrypto.swift`), which means the Mac's real next record
            // still opens and the session carries on. `phase` is deliberately
            // untouched: ending the session here would hand a hostile relay a
            // one-frame denial of service, and flashing "lost sync with this
            // Mac" before silently healing tells the person something untrue.
            NSLog("memterm: ignored a record addressed from \(hostId) that would not open")
            return
        }
        guard let message = RemoteMessage.decode(plaintext) else {
            // Unlike the case above, this record DID open, so the Mac really
            // sent it and really sent something this app does not know. That
            // is a version mismatch, and it does not get better by waiting.
            phase = .failed("Received something this app could not understand.")
            return
        }
        handle(message)
    }

    private func handle(_ message: RemoteMessage) {
        switch message {
        case .tree(let newTree):
            // Any tree answers a liveness probe: it proves the Mac still holds
            // this session, which is the only question the probe asked.
            cancelLivenessProbe()
            tree = newTree
            if let current = attachedPaneId {
                if !ViewerTree.contains(paneId: current, in: newTree) {
                    attachedPaneId = nil
                    phase = .ready
                }
            } else if let last = lastAttachedPaneId, ViewerTree.contains(paneId: last, in: newTree) {
                attach(paneId: last)
            } else {
                phase = .ready
            }
        // Neither `.screen` nor `.output` carries a pane id, so bytes the Mac
        // had already put in flight for a previous pane land in whatever
        // terminal view is current when the viewer re-attaches elsewhere.
        // Accepted rather than fixed: the Mac sends `.screen` on every attach,
        // which repaints over anything stale, and adding a pane id is a
        // protocol change this branch cannot make unilaterally (the browser
        // client speaks the same messages). Worth knowing before treating
        // these bytes as provably this pane's.
        case .screen(_, _, let bytes):
            if let paneId = attachedPaneId { phase = .attached(paneId: paneId) }
            onOutput?(bytes)
        case .output(let bytes):
            onOutput?(bytes)
        case .treeChanged:
            send(.list)
        case .refused(let reason):
            handleRefusal(reason)
        case .resized:
            break // the view asked for it; nothing to surface
        case .list, .attach, .detach, .input, .resize, .newTab, .unlock:
            break // client-only: we send these, we never receive them
        }
    }

    /// The Mac's refusal reasons are machine vocabulary
    /// (`RemoteHost+Dispatch.swift` sends `"unknown-pane"`, `"locked"`,
    /// `"unsupported"`), and NONE of them ends a session: each answers
    /// exactly one request the Mac would not carry out. Showing them as a
    /// fatal error put protocol words in an orange banner over a dead
    /// terminal — and the commonest one is sent precisely when a pane was
    /// pruned out from under the viewer, where the right answer is the quiet
    /// return to the tree this app already knows how to narrate. So each
    /// reason maps to the recovery that request needs, plus one sentence the
    /// person can act on wherever they would otherwise be left guessing.
    private func handleRefusal(_ reason: String) {
        switch reason {
        case "unknown-pane":
            // Exactly the vanished-pane path: drop the attachment, go back to
            // the tree, ask for a fresh one. `TerminalScreen` dismisses on
            // `.ready` and `TreeView` says the pane was closed, so this one
            // needs no sentence of its own.
            attachedPaneId = nil
            lastAttachedPaneId = nil
            phase = .ready
            send(.list)
        case "locked":
            returnToTree(saying: "That workspace is locked on \(host.name). Unlock it there, then try again.")
        case "unsupported":
            returnToTree(saying: "memterm can't attach to that kind of pane yet.")
        default:
            // A reason this app does not know is still one request refused,
            // not a session lost — and the word itself is not shown.
            returnToTree(saying: "\(host.name) would not do that.")
        }
    }

    /// Back to the tree with something readable, and with no pane remembered:
    /// a pane the Mac refuses must not be re-attached automatically on the
    /// next foreground, which would only be refused again.
    private func returnToTree(saying sentence: String) {
        attachedPaneId = nil
        lastAttachedPaneId = nil
        notice = sentence
        phase = .ready
    }

    // MARK: - Sending

    private func send(_ message: RemoteMessage) {
        guard let keys, let connection else {
            // A keystroke or a resize from before the handshake finished (or
            // after a teardown) has nowhere to go: there is no key to seal it
            // under. Dropping it is right; dropping it silently is how "my
            // typing vanished" becomes unexplainable.
            NSLog("memterm: dropped a \(message.tag) for \(hostId) — no session keys yet")
            return
        }
        guard let sealed = try? keys.seal(message.encode()) else {
            // Near-unreachable (seal only fails on a hardware/entropy
            // fault), but a silently swallowed failure here is exactly the
            // shape of bug this project has already paid for twice: treat
            // it the same as an unreadable record, not a no-op. `stop()`
            // first (it sets `.idle`), then `.failed` so that is the phase
            // left standing, not the one `stop()` passes through.
            stop()
            phase = .failed("The session with this Mac could not be continued.")
            return
        }
        let envelope = RemoteEnvelope(to: hostId, from: signer.id, payload: sealed)
        connection.send(envelope: envelope, completion: nil)
    }
}
