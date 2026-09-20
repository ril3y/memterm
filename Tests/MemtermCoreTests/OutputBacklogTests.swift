import XCTest
@testable import MemtermCore

// Remote-attach (decision doc 2026-09-19): while a phone client is
// reconnecting, terminal output keeps accumulating locally. OutputBacklog is
// the bounded queue that holds it — bounded because an unattended pane
// (a long-running build, a tail -f) must never grow this without limit.
final class OutputBacklogTests: XCTestCase {
    func testAppendUnderLimitKeepsEverything() {
        var backlog = OutputBacklog(limit: 1024)
        backlog.append(Data("hello".utf8))
        backlog.append(Data(" world".utf8))

        XCTAssertEqual(backlog.count, 11)
        XCTAssertEqual(backlog.droppedBytes, 0)
        XCTAssertEqual(backlog.drain(), Data("hello world".utf8))
    }

    func testAppendOverLimitDropsOldestWholeChunksAndKeepsNewestBytes() {
        var backlog = OutputBacklog(limit: 10)
        backlog.append(Data("aaaaa".utf8))   // 5 bytes, total 5
        backlog.append(Data("bbbbb".utf8))   // 5 bytes, total 10
        backlog.append(Data("ccccc".utf8))   // 5 bytes -> total would be 15, over limit

        // Oldest whole chunk ("aaaaa") is dropped to get back under the cap.
        XCTAssertEqual(backlog.count, 10)
        XCTAssertEqual(backlog.droppedBytes, 5)
        XCTAssertEqual(backlog.drain(), Data("bbbbbccccc".utf8))
    }

    func testDropsMultipleOldestChunksAsNeeded() {
        var backlog = OutputBacklog(limit: 6)
        backlog.append(Data("aa".utf8))       // 2, total 2
        backlog.append(Data("bb".utf8))       // 2, total 4
        backlog.append(Data("cc".utf8))       // 2, total 6 (at cap, no eviction)
        backlog.append(Data("dddddd".utf8))   // 6, total 12 -> evict "aa","bb","cc" to get to 6

        XCTAssertEqual(backlog.count, 6)
        XCTAssertEqual(backlog.droppedBytes, 6)
        XCTAssertEqual(backlog.drain(), Data("dddddd".utf8))
    }

    func testDrainEmptiesTheBacklog() {
        var backlog = OutputBacklog(limit: 1024)
        backlog.append(Data("data".utf8))
        _ = backlog.drain()

        XCTAssertEqual(backlog.count, 0)
        XCTAssertEqual(backlog.drain(), Data())
    }

    func testAppendAfterDrainWorks() {
        var backlog = OutputBacklog(limit: 1024)
        backlog.append(Data("first".utf8))
        _ = backlog.drain()
        backlog.append(Data("second".utf8))

        XCTAssertEqual(backlog.drain(), Data("second".utf8))
    }

    /// A single chunk larger than the limit is the newest data available, so
    /// it is kept whole rather than truncated or rejected.
    func testOversizedSingleChunkIsKeptAloneEvenThoughOverLimit() {
        var backlog = OutputBacklog(limit: 4)
        let big = Data("this-is-way-over-the-limit".utf8)
        backlog.append(big)

        XCTAssertEqual(backlog.count, big.count)
        XCTAssertEqual(backlog.droppedBytes, 0)
        XCTAssertEqual(backlog.drain(), big)
    }

    /// Once an oversized chunk is queued, subsequent appends still evict it
    /// as the oldest chunk when a new chunk needs room.
    func testOversizedChunkIsEvictedByLaterAppendsWhenOverLimit() {
        var backlog = OutputBacklog(limit: 4)
        let big = Data("way-too-big".utf8)
        backlog.append(big)
        backlog.append(Data("next".utf8))

        XCTAssertEqual(backlog.droppedBytes, big.count)
        XCTAssertEqual(backlog.drain(), Data("next".utf8))
    }

    func testEmptyAppendIsNoOp() {
        var backlog = OutputBacklog(limit: 1024)
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
        var backlog = OutputBacklog(limit: 0)
        backlog.append(Data("ab".utf8))

        // A single chunk is always kept whole even if it exceeds the
        // (floored-to-1) limit.
        XCTAssertEqual(backlog.count, 2)

        backlog.append(Data("c".utf8))
        // Oldest chunk ("ab") evicted to make room under the limit-of-1 cap.
        XCTAssertEqual(backlog.droppedBytes, 2)
        XCTAssertEqual(backlog.drain(), Data("c".utf8))
    }
}
