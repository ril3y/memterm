import Foundation
@testable import MemtermRemoteKit

/// A transport the test drives by hand: it records outbound frames and lets
/// the test push inbound frames or a failure into the pending receive.
final class FakeWebSocketTransport: WebSocketTransport {
    let url: URL
    private(set) var sent: [String] = []
    private(set) var pings = 0
    private(set) var cancelled = false
    private(set) var resumed = false
    private var pending: ((Result<String, Error>) -> Void)?

    init(url: URL) { self.url = url }
    func resume() { resumed = true }
    func send(_ text: String, completion: @escaping (Error?) -> Void) { sent.append(text); completion(nil) }
    func sendPing(_ completion: @escaping (Error?) -> Void) { pings += 1; completion(nil) }
    func receive(_ handler: @escaping (Result<String, Error>) -> Void) { pending = handler }
    func cancel() { cancelled = true }

    /// Delivers one inbound frame to whoever is waiting (synchronously).
    func push(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let handler = pending; pending = nil
        handler?(.success(String(data: data, encoding: .utf8)!))
    }
    func fail(_ message: String) {
        let handler = pending; pending = nil
        handler?(.failure(NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
    }
    var lastSent: [String: Any]? {
        guard let last = sent.last, let data = last.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

final class FakeTransportFactory: WebSocketTransportFactory {
    private(set) var made: [FakeWebSocketTransport] = []
    func makeTransport(url: URL) -> WebSocketTransport {
        let t = FakeWebSocketTransport(url: url); made.append(t); return t
    }
    var current: FakeWebSocketTransport { made.last! }
}

/// A manual scheduler: work runs only when the test says `fire()`.
final class FakeScheduler {
    private(set) var queue: [(delay: TimeInterval, item: DispatchWorkItem)] = []
    func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: body); queue.append((delay, item)); return item
    }
    /// Runs and removes the earliest pending item that was not cancelled.
    /// Cancelled entries ahead of it (e.g. a ping timer superseded by a
    /// reconnect) are discarded without running, matching the doc comment:
    /// a single `fireNext()` always advances to the next *live* item.
    func fireNext() {
        while !queue.isEmpty {
            let (_, item) = queue.removeFirst()
            if !item.isCancelled { item.perform(); return }
        }
    }
    var pendingDelays: [TimeInterval] { queue.filter { !$0.item.isCancelled }.map(\.delay) }
}
