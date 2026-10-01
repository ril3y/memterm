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
    /// Runs and removes the earliest pending, uncancelled item scheduled at
    /// `delay`, leaving every other entry queued — so a test can name the
    /// timer it means instead of counting past whichever others happen to be
    /// armed (a connection's 30 s ping sits in this same queue alongside a
    /// caller's own timeouts). Returns false when there is no such item.
    @discardableResult
    public func fire(delay: TimeInterval) -> Bool {
        guard let index = queue.firstIndex(where: { !$0.item.isCancelled && $0.delay == delay }) else {
            return false
        }
        let (_, item) = queue.remove(at: index)
        item.perform()
        return true
    }

    public var pendingDelays: [TimeInterval] { queue.filter { !$0.item.isCancelled }.map(\.delay) }
}
