import Foundation
import MemtermRemoteKit

/// A transport the test drives by hand: it records outbound frames and lets
/// the test push inbound frames or a failure into the pending receive.
public final class FakeWebSocketTransport: WebSocketTransport {
    public let url: URL
    public private(set) var sent: [String] = []
    public private(set) var pings = 0
    public private(set) var cancelled = false
    public private(set) var resumed = false
    private var pending: ((Result<String, Error>) -> Void)?

    public init(url: URL) { self.url = url }
    public func resume() { resumed = true }
    public func send(_ text: String, completion: @escaping (Error?) -> Void) { sent.append(text); completion(nil) }
    public func sendPing(_ completion: @escaping (Error?) -> Void) { pings += 1; completion(nil) }
    public func receive(_ handler: @escaping (Result<String, Error>) -> Void) { pending = handler }
    public func cancel() { cancelled = true }

    /// Delivers one inbound frame to whoever is waiting (synchronously).
    public func push(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let handler = pending; pending = nil
        handler?(.success(String(data: data, encoding: .utf8)!))
    }
    public func fail(_ message: String) {
        let handler = pending; pending = nil
        handler?(.failure(NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
    }
    public var lastSent: [String: Any]? {
        guard let last = sent.last, let data = last.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Every outbound frame whose `"type"` is `"env"`, decoded as a
    /// `RemoteEnvelope` — so a test can read what was actually sent on the
    /// wire without re-parsing JSON itself.
    public var sentEnvelopes: [RemoteEnvelope] {
        sent.compactMap { text -> RemoteEnvelope? in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "env"
            else { return nil }
            return RemoteEnvelope.decode(data)
        }
    }
}

public final class FakeTransportFactory: WebSocketTransportFactory {
    public private(set) var made: [FakeWebSocketTransport] = []
    public init() {}
    public func makeTransport(url: URL) -> WebSocketTransport {
        let t = FakeWebSocketTransport(url: url); made.append(t); return t
    }
    public var current: FakeWebSocketTransport { made.last! }
}
