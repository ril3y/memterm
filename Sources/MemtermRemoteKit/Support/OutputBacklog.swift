import Foundation

/// Remote-attach (decision doc 2026-09-19): while a phone client is
/// detached, reconnecting, or simply not reading fast enough, terminal
/// output for an attached pane keeps arriving locally and must be buffered
/// so it can be replayed on reattach — and so a stalled reader never makes
/// the Mac's own memory grow without bound. `OutputBacklog` is a bounded
/// FIFO queue of byte chunks: once the total queued byte count would exceed
/// `limit`, the OLDEST whole chunks are dropped (never split) until the
/// total is back under the limit.
///
/// A single chunk larger than `limit` is a special case: since it is the
/// newest data available, and the newest data is by definition what a
/// reattaching client most needs, it is kept in full rather than being
/// truncated or rejected. Such an oversized chunk can still be evicted
/// later, as the oldest chunk, when a subsequent append needs room.
///
/// FR-60 (final-review Important 2): the cap above is only real if
/// something can hold data back from the transport for a while — a viewer
/// that appends and immediately drains on every chunk never lets the queue
/// grow past one chunk, so eviction can never trigger and the true queue
/// becomes the OS socket's own unbounded send buffer. `pump(send:)` is the
/// other half: it tracks bytes currently in flight to the transport and
/// only starts a new send while that total is under `inFlightThreshold`,
/// leaving anything it can't send yet queued here — subject to the same
/// oldest-dropped-first eviction — until the caller's completion handler
/// calls `pump` again. `OutputBacklog` stays AppKit-free and knows nothing
/// about sockets: the caller supplies `send`, and the type only accounts
/// bytes.
public final class OutputBacklog {
    private var chunks: [Data] = []
    private var total: Int = 0
    private let limit: Int
    private var dropped: Int = 0
    private var inFlight: Int = 0
    private let inFlightThreshold: Int

    /// - Parameters:
    ///   - limit: maximum total queued bytes before oldest chunks are
    ///     evicted. Values less than 1 are treated as 1 (a backlog with no
    ///     capacity at all would be able to hold nothing, including the very
    ///     newest chunk, which defeats the purpose of a backlog).
    ///   - inFlightThreshold: `pump(send:)` starts a new send only while
    ///     fewer than this many bytes are already in flight to the
    ///     transport. Values less than 1 are treated as 1, for the same
    ///     reason as `limit`.
    public init(limit: Int = 256 * 1024, inFlightThreshold: Int = 64 * 1024) {
        self.limit = max(1, limit)
        self.inFlightThreshold = max(1, inFlightThreshold)
    }

    /// Total bytes currently queued (not yet handed to `send`).
    public var count: Int { total }

    /// Total bytes ever discarded to stay under `limit`.
    public var droppedBytes: Int { dropped }

    /// Bytes handed to `send` whose completion has not yet fired. Exposed
    /// for tests and host-side health signals.
    public var inFlightBytes: Int { inFlight }

    /// Appends a chunk of output, then evicts oldest whole chunks (but never
    /// the chunk just appended) until the queue is back at or under the
    /// limit. Does not send anything itself — call `pump(send:)` (typically
    /// right after `append`) to attempt delivery.
    public func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }

        chunks.append(bytes)
        total += bytes.count

        while total > limit, chunks.count > 1 {
            let oldest = chunks.removeFirst()
            total -= oldest.count
            dropped += oldest.count
        }
    }

    /// Returns all queued bytes, in order, and empties the backlog, with no
    /// regard for `inFlightThreshold`. `droppedBytes` is a lifetime counter
    /// and is not reset. Kept for callers (and tests) that want the
    /// coalescing behavior alone, without backpressure; `pump(send:)` is the
    /// one production callers should use.
    public func drain() -> Data {
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

    /// Coalesces everything currently queued into one blob and hands it to
    /// `send`, but only while fewer than `inFlightThreshold` bytes are
    /// already in flight — otherwise this is a no-op and the queued bytes
    /// stay put (subject to `limit` eviction on the next `append`).
    ///
    /// `send`'s completion closure MUST eventually be called exactly once,
    /// from whatever thread the transport calls back on; `pump` itself does
    /// no threading — the caller (RemotePaneStream, in the app target) is
    /// responsible for hopping to the right thread before touching this
    /// object again. On completion, the just-sent bytes are removed from
    /// `inFlightBytes` and `pump` is called again, so a completed send that
    /// finds more queued behind it keeps draining without the caller having
    /// to re-invoke `pump` from every completion site by hand — though doing
    /// so anyway is harmless (a redundant call is just a no-op).
    public func pump(send: @escaping (Data, @escaping () -> Void) -> Void) {
        guard inFlight < inFlightThreshold else { return }
        let blob = drain()
        guard !blob.isEmpty else { return }
        let byteCount = blob.count
        inFlight += byteCount
        send(blob) { [weak self] in
            guard let self else { return }
            self.inFlight -= byteCount
            self.pump(send: send)
        }
    }
}
