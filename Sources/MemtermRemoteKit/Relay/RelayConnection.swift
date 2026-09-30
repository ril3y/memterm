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
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = RelayConnection.mainQueueSchedule) {
        self.base = base; self.role = role; self.signer = signer
        self.extraAuthFields = extraAuthFields; self.events = events
        self.transports = transports; self.schedule = schedule
    }

    public static func mainQueueSchedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    // MARK: - Lifecycle

    public func start() {
        running = true
        connect()
    }

    public func stop() {
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
        generation += 1
        let gen = generation
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/" + role.rawValue
        guard let url = parts?.url else { setState(.offline("relay URL is not usable")); return }
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
            var auth: [String: Any] = [
                "type": "auth",
                "publicKey": signer.publicKeySPKI.base64EncodedString(),
                "signature": signer.sign(nonce).base64EncodedString(),
            ]
            for (key, value) in extraAuthFields() { auth[key] = value }
            send(control: auth)
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

    public func send(control object: [String: Any]) {
        guard let transport, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        transport.send(text) { _ in }
    }

    /// The completion fires exactly once, on the main queue, whether the
    /// frame was sent, failed, or there was no socket to send it on — a
    /// caller counting in-flight bytes must never wait forever.
    public func send(envelope: RemoteEnvelope, completion: (() -> Void)?) {
        guard let transport, let text = String(data: envelope.encode(), encoding: .utf8) else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        transport.send(text) { _ in
            guard let completion else { return }
            Self.onMain(completion)
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
