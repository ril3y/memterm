import Foundation

/// Remote-attach (decision doc 2026-09-19): while a phone client is
/// detached or reconnecting, terminal output for an attached pane keeps
/// arriving locally and must be buffered so it can be replayed on
/// reattach. `OutputBacklog` is a bounded FIFO queue of byte chunks: once
/// the total queued byte count would exceed `limit`, the OLDEST whole
/// chunks are dropped (never split) until the total is back under the
/// limit.
///
/// A single chunk larger than `limit` is a special case: since it is the
/// newest data available, and the newest data is by definition what a
/// reattaching client most needs, it is kept in full rather than being
/// truncated or rejected. Such an oversized chunk can still be evicted
/// later, as the oldest chunk, when a subsequent append needs room.
public struct OutputBacklog {
    private var chunks: [Data] = []
    private var total: Int = 0
    private let limit: Int
    private var dropped: Int = 0

    /// - Parameter limit: maximum total queued bytes before oldest chunks
    ///   are evicted. Values less than 1 are treated as 1 (a backlog with no
    ///   capacity at all would be able to hold nothing, including the very
    ///   newest chunk, which defeats the purpose of a backlog).
    public init(limit: Int = 256 * 1024) {
        self.limit = max(1, limit)
    }

    /// Total bytes currently queued.
    public var count: Int { total }

    /// Total bytes ever discarded to stay under `limit`.
    public var droppedBytes: Int { dropped }

    /// Appends a chunk of output, then evicts oldest whole chunks (but never
    /// the chunk just appended) until the queue is back at or under the
    /// limit.
    public mutating func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }

        chunks.append(bytes)
        total += bytes.count

        while total > limit, chunks.count > 1 {
            let oldest = chunks.removeFirst()
            total -= oldest.count
            dropped += oldest.count
        }
    }

    /// Returns all queued bytes, in order, and empties the backlog.
    /// `droppedBytes` is a lifetime counter and is not reset.
    public mutating func drain() -> Data {
        guard !chunks.isEmpty else { return Data() }
        var result = Data()
        result.reserveCapacity(total)
        for chunk in chunks {
            result.append(chunk)
        }
        chunks.removeAll()
        total = 0
        return result
    }
}
