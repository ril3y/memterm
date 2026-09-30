import Foundation

/// The relay client shared by the Mac host (`/host`) and the phone
/// (`/client`): challenge/auth, envelope framing, a 30 s ping, a receive
/// loop guarded by a generation counter, and reconnect with backoff
/// 1 s → 30 s. It knows nothing about sessions, pairing, or devices; those
/// live in the caller and are driven by `Events`.
///
/// Threading: `start`, `stop`, and both `send`s are main-queue only. Every
/// callback is delivered on the main queue, in receive order. Transport
/// completions may arrive on any queue and are hopped to main here.
public final class RelayConnection {
    public enum Role: String { case host, client }
    public enum State: Equatable { case off, connecting, connected, offline(String?) }

    public struct Events {
        public var onState: (State) -> Void = { _ in }
        /// Every relay control object (anything whose "type" is not "env"),
        /// `authed` included — after the connection has updated its own state.
        public var onControl: ([String: Any]) -> Void = { _ in }
        public var onEnvelope: (RemoteEnvelope) -> Void = { _ in }
        /// A transport-reported error sending a control frame the
        /// connection itself originates (currently just `auth`). Frames the
        /// caller sends through `send(control:onFailure:)` report their own
        /// failures directly; this is only for the kit's own internal send.
        public var onSendFailure: (Error) -> Void = { _ in }
        public init() {}
    }

    public static let pingInterval: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 30

    public private(set) var state: State = .off

    private let base: URL
    private let role: Role
    private let signer: RemoteSigner
    private let extraAuthFields: () -> [String: Any]
    private let events: Events
    private let transports: WebSocketTransportFactory
    private let schedule: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem
    private let makeConnectURL: (URL, Role) -> URL?

    private var transport: WebSocketTransport?
    private var generation = 0
    private var backoff: TimeInterval = 1
    private var reconnectWork: DispatchWorkItem?
    private var pingWork: DispatchWorkItem?
    private var running = false

    public init(base: URL, role: Role, signer: RemoteSigner,
                extraAuthFields: @escaping () -> [String: Any] = { [:] },
                events: Events,
                transports: WebSocketTransportFactory = URLSessionTransportFactory(),
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = RelayConnection.mainQueueSchedule,
                makeConnectURL: @escaping (URL, Role) -> URL? = RelayConnection.connectURL) {
        self.base = base; self.role = role; self.signer = signer
        self.extraAuthFields = extraAuthFields; self.events = events
        self.transports = transports; self.schedule = schedule
        self.makeConnectURL = makeConnectURL
    }

    deinit {
        // Cheap insurance for a caller (an iOS view model, most likely) that
        // drops its last reference without calling `stop()` first: leaves no
        // socket open and resumed. Both Mac-side teardown paths call `stop()`
        // before releasing their reference, so this is a no-op there today.
        transport?.cancel()
    }

    public static func mainQueueSchedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    /// `/host` or `/client` appended to `base`'s path. Injectable (like
    /// `transports` and `schedule` above) purely so a test can simulate the
    /// nil case below deterministically: on every `URL` this was actually
    /// tried against, `URLComponents` proved too lenient at read-time to
    /// ever produce it from a real, publicly-constructible `URL` — the
    /// guard in `connect()` is real defensive code, but not one a live
    /// `base` value can be made to trip.
    public static func connectURL(_ base: URL, _ role: Role) -> URL? {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/" + role.rawValue
        return parts?.url
    }

    // MARK: - Lifecycle

    public func start() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        running = true
        connect()
    }

    public func stop() {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        running = false
        generation += 1
        reconnectWork?.cancel(); reconnectWork = nil
        pingWork?.cancel(); pingWork = nil
        transport?.cancel(); transport = nil
        backoff = 1
        setState(.off)
    }

    private func connect() {
        guard running else { return }
        // A socket we are about to replace must be closed, not merely
        // orphaned: the generation guard stops us reading it, but it would
        // stay open and authenticated at the relay.
        transport?.cancel(); transport = nil
        generation += 1
        let gen = generation
        guard let url = makeConnectURL(base, role) else {
            // An unusable base URL is a configuration error, not a transient
            // failure: no amount of retrying will ever produce a path where
            // none can be formed, so this must not leave `running == true`
            // with a reconnect that can never succeed. `off`, not `offline`,
            // matches the Mac host's own handling of the same case.
            running = false
            setState(.off)
            return
        }
        setState(.connecting)
        let socket = transports.makeTransport(url: url)
        transport = socket
        socket.resume()
        receive(on: socket, generation: gen)
        schedulePing(generation: gen)
    }

    private func receive(on socket: WebSocketTransport, generation gen: Int) {
        socket.receive { [weak self] result in
            Self.onMain {
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.handleFailure(error)
                case .success(let text):
                    self.handleFrame(Data(text.utf8))
                    // handleFrame can itself call handleFailure (a challenge
                    // whose signing throws): that cancels and nils transport
                    // without bumping generation, since it retries through
                    // the same reconnect path a socket failure does. Without
                    // this check, re-arming unconditionally would register
                    // another receive on the now-cancelled socket, which
                    // completes with a cancellation error and drives a
                    // second, spurious handleFailure.
                    guard self.transport === socket else { return }
                    self.receive(on: socket, generation: gen)
                }
            }
        }
    }

    private func handleFailure(_ error: Error) {
        // The socket is already dead; cancel it so nothing lingers, then drop
        // it — a send between the failure and the reconnect is a no-op, which
        // is what the Mac host did before this connection existed.
        pingWork?.cancel(); pingWork = nil
        transport?.cancel()
        transport = nil
        setState(.offline(error.localizedDescription))
        guard running else { return }
        let work = schedule(backoff) { [weak self] in self?.connect() }
        reconnectWork = work
        backoff = min(backoff * 2, Self.maxBackoff)
    }

    private func schedulePing(generation gen: Int) {
        pingWork?.cancel()
        pingWork = schedule(Self.pingInterval) { [weak self] in
            guard let self, gen == self.generation, let socket = self.transport else { return }
            socket.sendPing { _ in }
            self.schedulePing(generation: gen)
        }
    }

    // MARK: - Frames

    private func handleFrame(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "challenge":
            guard let nonceB64 = object["nonce"] as? String, let nonce = Data(base64Encoded: nonceB64) else { return }
            let signature: Data
            do {
                signature = try signer.sign(nonce)
            } catch {
                // A signing failure here is not a protocol error — on the
                // phone it is the ordinary case of a locked device, a
                // cancelled biometric prompt, or a Secure Enclave timeout.
                // Route it to the SAME path a dead socket takes: `.offline`
                // plus the existing reconnect backoff, since a locked phone
                // may be unlocked by the time the backoff fires. Sending an
                // empty signature instead would make the relay drop the
                // socket anyway, but with no error to show for it.
                handleFailure(error)
                return
            }
            var auth: [String: Any] = [
                "type": "auth",
                "publicKey": signer.publicKeySPKI.base64EncodedString(),
                "signature": signature.base64EncodedString(),
            ]
            for (key, value) in extraAuthFields() { auth[key] = value }
            send(control: auth, onFailure: events.onSendFailure)
            // The connection answers the challenge itself, but it still
            // reports it to the caller — a host logs the handshake it just
            // took part in, which is how "connects but never authenticates"
            // is told apart from "never connects at all" (field bug
            // 2026-09-21/22).
            events.onControl(object)
        case "authed":
            backoff = 1
            setState(.connected)
            events.onControl(object)
        case "env":
            guard let envelope = RemoteEnvelope.decode(data) else { return }
            events.onEnvelope(envelope)
        default:
            events.onControl(object)
        }
    }

    // MARK: - Sending

    /// `onFailure`, when given, fires on the main queue with whatever error
    /// the transport reported — never called when there was no transport to
    /// send on at all, matching `RemoteHost`'s original `sendJSON`, which
    /// only ever logged a transport-reported send error, not a missing
    /// socket (that case is silent by design: a control frame with nowhere
    /// to go is not worth alarming about).
    public func send(control object: [String: Any], onFailure: ((Error) -> Void)? = nil) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        guard let transport, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        transport.send(text) { error in
            guard let error, let onFailure else { return }
            Self.onMain { onFailure(error) }
        }
    }

    /// The completion fires exactly once, always via `DispatchQueue.main.async`
    /// (never inline, even when already on main), whether the frame was
    /// sent, failed, or there was no socket to send it on — a caller
    /// counting in-flight bytes must never wait forever, and a synchronous
    /// completion on the sent path would re-enter `RemotePaneStream`'s pump
    /// while it is still mid-call. This matches `RemoteHost.sendEnvelope`,
    /// which the move to this class carried forward.
    public func send(envelope: RemoteEnvelope, completion: (() -> Void)?) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        guard let transport, let text = String(data: envelope.encode(), encoding: .utf8) else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        transport.send(text) { _ in
            guard let completion else { return }
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: - Helpers

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        events.onState(new)
    }

    static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}
