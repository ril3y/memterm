import XCTest
@testable import MemtermCore

// Remote-attach (decision doc 2026-09-19): while a phone client is
// reconnecting, terminal output keeps accumulating locally. OutputBacklog is
// the bounded queue that holds it — bounded because an unattended pane
// (a long-running build, a tail -f) must never grow this without limit.
final class OutputBacklogTests: XCTestCase {
    func testAppendUnderLimitKeepsEverything() {
        let backlog = OutputBacklog(limit: 1024)
        backlog.append(Data("hello".utf8))
        backlog.append(Data(" world".utf8))

        XCTAssertEqual(backlog.count, 11)
        XCTAssertEqual(backlog.droppedBytes, 0)
        XCTAssertEqual(backlog.drain(), Data("hello world".utf8))
    }

    func testAppendOverLimitDropsOldestWholeChunksAndKeepsNewestBytes() {
        let backlog = OutputBacklog(limit: 10)
        backlog.append(Data("aaaaa".utf8))   // 5 bytes, total 5
        backlog.append(Data("bbbbb".utf8))   // 5 bytes, total 10
        backlog.append(Data("ccccc".utf8))   // 5 bytes -> total would be 15, over limit

        // Oldest whole chunk ("aaaaa") is dropped to get back under the cap.
        XCTAssertEqual(backlog.count, 10)
        XCTAssertEqual(backlog.droppedBytes, 5)
        XCTAssertEqual(backlog.drain(), Data("bbbbbccccc".utf8))
    }

    func testDropsMultipleOldestChunksAsNeeded() {
        let backlog = OutputBacklog(limit: 6)
        backlog.append(Data("aa".utf8))       // 2, total 2
        backlog.append(Data("bb".utf8))       // 2, total 4
        backlog.append(Data("cc".utf8))       // 2, total 6 (at cap, no eviction)
        backlog.append(Data("dddddd".utf8))   // 6, total 12 -> evict "aa","bb","cc" to get to 6

        XCTAssertEqual(backlog.count, 6)
        XCTAssertEqual(backlog.droppedBytes, 6)
        XCTAssertEqual(backlog.drain(), Data("dddddd".utf8))
    }

    func testDrainEmptiesTheBacklog() {
        let backlog = OutputBacklog(limit: 1024)
        backlog.append(Data("data".utf8))
        _ = backlog.drain()

        XCTAssertEqual(backlog.count, 0)
        XCTAssertEqual(backlog.drain(), Data())
    }

    func testAppendAfterDrainWorks() {
        let backlog = OutputBacklog(limit: 1024)
        backlog.append(Data("first".utf8))
        _ = backlog.drain()
        backlog.append(Data("second".utf8))

        XCTAssertEqual(backlog.drain(), Data("second".utf8))
    }

    /// A single chunk larger than the limit is the newest data available, so
    /// it is kept whole rather than truncated or rejected.
    func testOversizedSingleChunkIsKeptAloneEvenThoughOverLimit() {
        let backlog = OutputBacklog(limit: 4)
        let big = Data("this-is-way-over-the-limit".utf8)
        backlog.append(big)

        XCTAssertEqual(backlog.count, big.count)
        XCTAssertEqual(backlog.droppedBytes, 0)
        XCTAssertEqual(backlog.drain(), big)
    }

    /// Once an oversized chunk is queued, subsequent appends still evict it
    /// as the oldest chunk when a new chunk needs room.
    func testOversizedChunkIsEvictedByLaterAppendsWhenOverLimit() {
        let backlog = OutputBacklog(limit: 4)
        let big = Data("way-too-big".utf8)
        backlog.append(big)
        backlog.append(Data("next".utf8))

        XCTAssertEqual(backlog.droppedBytes, big.count)
        XCTAssertEqual(backlog.drain(), Data("next".utf8))
    }

    func testEmptyAppendIsNoOp() {
        let backlog = OutputBacklog(limit: 1024)
        backlog.append(Data())

        XCTAssertEqual(backlog.count, 0)
        XCTAssertEqual(backlog.droppedBytes, 0)
    }

    func testDefaultLimitIs256KiB() {
        let backlog = OutputBacklog()
        XCTAssertEqual(backlog.count, 0)
        XCTAssertEqual(backlog.droppedBytes, 0)
        _ = backlog // limit itself isn't exposed; default is exercised via behavior in other tests.
    }

    func testLimitLessThanOneIsTreatedAsOne() {
        let backlog = OutputBacklog(limit: 0)
        backlog.append(Data("ab".utf8))

        // A single chunk is always kept whole even if it exceeds the
        // (floored-to-1) limit.
        XCTAssertEqual(backlog.count, 2)

        backlog.append(Data("c".utf8))
        // Oldest chunk ("ab") evicted to make room under the limit-of-1 cap.
        XCTAssertEqual(backlog.droppedBytes, 2)
        XCTAssertEqual(backlog.drain(), Data("c".utf8))
    }

    // MARK: - pump(send:) backpressure (final-review Important 2)
    //
    // A fake sender stands in for RemoteHost's socket send: it records every
    // blob it is asked to send and hands back the completion closure instead
    // of calling it, so the test controls exactly when a "send" finishes —
    // simulating a stalled reader (a backgrounded phone, a TCP zero-window)
    // that never lets the transport drain.

    private final class FakeSender {
        private(set) var sent: [Data] = []
        private var completions: [() -> Void] = []

        func send(_ data: Data, _ completion: @escaping () -> Void) {
            sent.append(data)
            completions.append(completion)
        }

        /// Fires the Nth recorded send's completion (0 = first).
        func release(_ index: Int) {
            completions[index]()
        }
    }

    /// Enqueuing more than the 256 KiB cap while the one in-flight send never
    /// completes must still drop the oldest bytes — proving the cap is real
    /// even though nothing has been "sent" successfully yet.
    func testPumpDropsOldestBytesWhileSenderIsStalled() {
        let backlog = OutputBacklog(limit: 256 * 1024, inFlightThreshold: 64 * 1024)
        let sender = FakeSender()

        // Prime a first send whose single chunk already exceeds the 64 KiB
        // in-flight threshold on its own, so it never completes in this test
        // and every later pump() call is a guaranteed no-op — a real stall.
        backlog.append(Data(repeating: 0xAA, count: 70_000))
        backlog.pump(send: sender.send)
        XCTAssertEqual(sender.sent.count, 1)
        XCTAssertEqual(backlog.inFlightBytes, 70_000)

        // Now push well over the 256 KiB cap while that send is stalled.
        // Nothing new should be sent (in-flight is still over threshold),
        // so this all queues up and the cap's own eviction has to fire.
        for i in 0..<40 {
            backlog.append(Data(repeating: UInt8(i), count: 8_000)) // 320,000 bytes total
            backlog.pump(send: sender.send)
        }

        XCTAssertEqual(sender.sent.count, 1, "sender is stalled — pump must not start a second send")
        XCTAssertGreaterThan(backlog.droppedBytes, 0, "over-cap bytes queued during the stall must be dropped")

        // The newest chunk (i = 39) must have survived the eviction.
        let newestChunk = Data(repeating: 39, count: 8_000)

        // Release the stalled send: pump should immediately drain and send
        // whatever is left — the newest surviving bytes, not the dropped
        // ones.
        sender.release(0)

        XCTAssertEqual(sender.sent.count, 2, "releasing the stall must drain the backlog into a second send")
        XCTAssertEqual(backlog.inFlightBytes, sender.sent[1].count)
        XCTAssertEqual(sender.sent[1].suffix(newestChunk.count), newestChunk,
                       "delivered bytes after release must end in the newest queued chunk")
        XCTAssertLessThanOrEqual(sender.sent[1].count, 256 * 1024)
    }

    /// A viewer that keeps completing promptly never accumulates a backlog —
    /// pump should behave as an immediate coalesce-and-send.
    func testPumpSendsImmediatelyWhenNothingIsInFlight() {
        let backlog = OutputBacklog(limit: 1024, inFlightThreshold: 256)
        let sender = FakeSender()

        backlog.append(Data("hello".utf8))
        backlog.pump(send: sender.send)
        XCTAssertEqual(sender.sent, [Data("hello".utf8)])
        XCTAssertEqual(backlog.inFlightBytes, 5)

        sender.release(0)
        XCTAssertEqual(backlog.inFlightBytes, 0)

        backlog.append(Data(" world".utf8))
        backlog.pump(send: sender.send)
        XCTAssertEqual(sender.sent, [Data("hello".utf8), Data(" world".utf8)])
    }
}
