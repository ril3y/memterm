import Foundation

/// A manual scheduler: work runs only when the test says `fireNext()`.
public final class FakeScheduler {
    public private(set) var queue: [(delay: TimeInterval, item: DispatchWorkItem)] = []
    public init() {}
    public func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: body); queue.append((delay, item)); return item
    }
    /// Runs and removes the earliest pending item that was not cancelled.
    /// Cancelled entries ahead of it (e.g. a ping timer superseded by a
    /// reconnect) are discarded without running, matching the doc comment:
    /// a single `fireNext()` always advances to the next *live* item.
    public func fireNext() {
        while !queue.isEmpty {
            let (_, item) = queue.removeFirst()
            if !item.isCancelled { item.perform(); return }
        }
    }
    public var pendingDelays: [TimeInterval] { queue.filter { !$0.item.isCancelled }.map(\.delay) }
}
