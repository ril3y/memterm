import XCTest
@testable import MemtermCore

// SerialFooterModel — counters, human-unit formatting, the ≤4 Hz throttle
// (injected clock, no real timers), state-dot mapping, and the settings
// summary strings the footer strip renders.
final class SerialFooterModelTests: XCTestCase {

    // MARK: Byte formatting (exact strings — these render in a 22 pt strip)

    func testFormatBytesHumanUnits() {
        XCTAssertEqual(SerialFooterModel.formatBytes(0), "0 B")
        XCTAssertEqual(SerialFooterModel.formatBytes(1), "1 B")
        XCTAssertEqual(SerialFooterModel.formatBytes(1023), "1023 B")
        XCTAssertEqual(SerialFooterModel.formatBytes(1024), "1.0 KB")
        XCTAssertEqual(SerialFooterModel.formatBytes(1536), "1.5 KB")
        XCTAssertEqual(SerialFooterModel.formatBytes(10 * 1024 + 300), "10.3 KB")
        XCTAssertEqual(SerialFooterModel.formatBytes(348 * 1024), "348 KB")
        XCTAssertEqual(SerialFooterModel.formatBytes(1024 * 1024), "1.0 MB")
        XCTAssertEqual(SerialFooterModel.formatBytes(Int(12.7 * 1024 * 1024)), "12.7 MB")
        XCTAssertEqual(SerialFooterModel.formatBytes(250 * 1024 * 1024), "250 MB")
        XCTAssertEqual(SerialFooterModel.formatBytes(3 * 1024 * 1024 * 1024), "3.0 GB")
        XCTAssertEqual(SerialFooterModel.formatBytes(-5), "0 B")  // never negative
    }

    // MARK: Counters accumulate and never reset (persist across reconnects)

    func testCountersAccumulateAcrossRecords() {
        var model = SerialFooterModel()
        _ = model.recordTraffic(rx: 100, tx: 0, now: 0)
        _ = model.recordTraffic(rx: 24, tx: 7, now: 1)
        _ = model.recordTraffic(rx: 0, tx: 3, now: 2)
        XCTAssertEqual(model.rxBytes, 124)
        XCTAssertEqual(model.txBytes, 10)
        XCTAssertEqual(model.rxDisplay, "124 B")
        XCTAssertEqual(model.txDisplay, "10 B")
    }

    func testNegativeDeltasAreIgnoredNotSubtracted() {
        var model = SerialFooterModel()
        _ = model.recordTraffic(rx: 50, tx: 50, now: 0)
        _ = model.recordTraffic(rx: -10, tx: -10, now: 1)
        XCTAssertEqual(model.rxBytes, 50)
        XCTAssertEqual(model.txBytes, 50)
    }

    // MARK: Throttle — ≤4 Hz with a trailing flush so no bytes go unpainted

    func testFirstRecordEmitsImmediately() {
        var model = SerialFooterModel()
        XCTAssertTrue(model.recordTraffic(rx: 1, tx: 0, now: 100))
        XCTAssertFalse(model.hasPendingRepaint)
    }

    func testBurstWithinWindowIsThrottledThenFlushes() {
        var model = SerialFooterModel()  // minInterval 0.25
        XCTAssertTrue(model.recordTraffic(rx: 10, tx: 0, now: 100.0))
        // A flood of chunks inside the window: every one throttled.
        XCTAssertFalse(model.recordTraffic(rx: 10, tx: 0, now: 100.05))
        XCTAssertFalse(model.recordTraffic(rx: 10, tx: 0, now: 100.10))
        XCTAssertFalse(model.recordTraffic(rx: 10, tx: 0, now: 100.20))
        XCTAssertTrue(model.hasPendingRepaint)
        // Counters kept counting the whole time.
        XCTAssertEqual(model.rxBytes, 40)
        // Trailing-edge flush repaints exactly once...
        XCTAssertTrue(model.flushPendingRepaint(now: 100.25))
        XCTAssertFalse(model.hasPendingRepaint)
        // ...and a second flush with nothing pending is a no-op.
        XCTAssertFalse(model.flushPendingRepaint(now: 100.30))
    }

    func testRecordAfterWindowEmitsAgain() {
        var model = SerialFooterModel()
        XCTAssertTrue(model.recordTraffic(rx: 1, tx: 0, now: 100.0))
        XCTAssertFalse(model.recordTraffic(rx: 1, tx: 0, now: 100.1))
        XCTAssertTrue(model.recordTraffic(rx: 1, tx: 0, now: 100.26))
        XCTAssertFalse(model.hasPendingRepaint)  // the emit covered the backlog
    }

    func testEmitRateNeverExceedsFourHz() {
        var model = SerialFooterModel()
        var emits = 0
        // 10 seconds of 100 Hz chunks; count immediate emits + one trailing
        // flush per armed window (the AppKit face arms at most one).
        var flushArmedAt: TimeInterval? = nil
        for i in 0..<1000 {
            let t = Double(i) * 0.01
            if let due = flushArmedAt, t >= due {
                if model.flushPendingRepaint(now: t) { emits += 1 }
                flushArmedAt = nil
            }
            if model.recordTraffic(rx: 1, tx: 0, now: t) {
                emits += 1
            } else if flushArmedAt == nil {
                flushArmedAt = t + model.minInterval
            }
        }
        XCTAssertLessThanOrEqual(emits, 41)  // ≤4 Hz over 10 s (+1 edge)
        XCTAssertEqual(model.rxBytes, 1000)
    }

    // MARK: State dot

    func testLinkStateMapping() {
        XCTAssertEqual(SerialFooterModel.linkState(isConnected: true,
                                                   awaitingDeviceReturn: false),
                       .connected)
        // A live unplug arms awaitingDeviceReturn — orange.
        XCTAssertEqual(SerialFooterModel.linkState(isConnected: false,
                                                   awaitingDeviceReturn: true),
                       .reconnecting)
        // Restored pane / failed open: waiting on the ⌘R consent gesture.
        XCTAssertEqual(SerialFooterModel.linkState(isConnected: false,
                                                   awaitingDeviceReturn: false),
                       .disconnected)
    }

    // MARK: Settings summary

    func testSummaryStringsSplitAtTheClickableBaud() {
        let plain = SerialSettings()  // 115200-8N1, flow none
        XCTAssertEqual(SerialFooterModel.baudText(plain), "115200")
        XCTAssertEqual(SerialFooterModel.frameText(plain), "-8N1")

        let rtscts = SerialSettings(baud: 115200, flow: .rtscts)
        XCTAssertEqual(SerialFooterModel.frameText(rtscts), "-8N1 · RTS/CTS")

        let odd = SerialSettings(baud: 9600, dataBits: 7, parity: .even,
                                 stopBits: 2, flow: .xonxoff)
        XCTAssertEqual(SerialFooterModel.baudText(odd), "9600")
        XCTAssertEqual(SerialFooterModel.frameText(odd), "-7E2 · XON/XOFF")
    }

    func testFlowLabels() {
        XCTAssertNil(SerialFooterModel.flowLabel(.none))
        XCTAssertEqual(SerialFooterModel.flowLabel(.rtscts), "RTS/CTS")
        XCTAssertEqual(SerialFooterModel.flowLabel(.xonxoff), "XON/XOFF")
    }
}
