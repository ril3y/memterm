import XCTest
@testable import MemtermCore

final class TabActivityTests: XCTestCase {

    private func tracker() -> TabActivityTracker {
        TabActivityTracker(decayInterval: 1.5, coalesceInterval: 0.25)
    }

    func testIdleByDefault() {
        let t = tracker()
        XCTAssertEqual(t.state(at: 0), .idle)
        XCTAssertNil(t.nextDecay(after: 0))
    }

    func testOutputOnNonSelectedTabGoesActive() {
        var t = tracker()
        XCTAssertTrue(t.recordOutput(at: 10, isSelected: false))
        XCTAssertEqual(t.state(at: 10), .active)
        XCTAssertEqual(t.state(at: 11.4), .active)
    }

    func testActiveDecaysToUnseenAfterDecayInterval() {
        var t = tracker()
        _ = t.recordOutput(at: 10, isSelected: false)
        XCTAssertEqual(t.state(at: 11.5), .unseen)
        XCTAssertEqual(t.state(at: 100), .unseen, "unseen never decays on its own")
    }

    func testContinuedOutputKeepsActiveAlive() {
        var t = tracker()
        _ = t.recordOutput(at: 10, isSelected: false)
        _ = t.recordOutput(at: 11.4, isSelected: false)
        XCTAssertEqual(t.state(at: 12.8), .active, "decay counts from the LAST output")
        XCTAssertEqual(t.state(at: 12.91), .unseen)
    }

    func testSelectionClearsEverything() {
        var t = tracker()
        _ = t.recordOutput(at: 10, isSelected: false)
        t.recordSelected()
        XCTAssertEqual(t.state(at: 10.1), .idle)
        XCTAssertNil(t.nextDecay(after: 10.1))
    }

    func testOutputOnSelectedTabNeverMarks() {
        var t = tracker()
        XCTAssertFalse(t.recordOutput(at: 10, isSelected: true),
                       "nothing to clear, nothing to paint")
        XCTAssertEqual(t.state(at: 10), .idle)
    }

    func testOutputOnSelectedTabClearsStaleState() {
        var t = tracker()
        _ = t.recordOutput(at: 10, isSelected: false)
        // Tab got selected without a recordSelected (e.g. missed key event):
        // selected output self-heals and asks for one repaint.
        XCTAssertTrue(t.recordOutput(at: 12, isSelected: true))
        XCTAssertEqual(t.state(at: 12), .idle)
    }

    func testCoalescingLimitsPublishRate() {
        var t = tracker()
        XCTAssertTrue(t.recordOutput(at: 10.0, isSelected: false))
        XCTAssertFalse(t.recordOutput(at: 10.1, isSelected: false))
        XCTAssertFalse(t.recordOutput(at: 10.24, isSelected: false))
        XCTAssertTrue(t.recordOutput(at: 10.25, isSelected: false),
                      "a full coalesce interval later, publishing resumes")
        XCTAssertFalse(t.recordOutput(at: 10.3, isSelected: false))
    }

    func testCoalescedOutputStillCounts() {
        var t = tracker()
        _ = t.recordOutput(at: 10.0, isSelected: false)
        XCTAssertFalse(t.recordOutput(at: 10.1, isSelected: false))
        // The suppressed publish still advanced the decay clock.
        XCTAssertEqual(t.state(at: 11.55), .active)
        XCTAssertEqual(t.nextDecay(after: 10.2), 11.6)
    }

    func testNextDecayNilOncePastBoundary() {
        var t = tracker()
        _ = t.recordOutput(at: 10, isSelected: false)
        XCTAssertEqual(t.nextDecay(after: 10.0), 11.5)
        XCTAssertNil(t.nextDecay(after: 11.5), "already unseen — no transition pending")
    }

    func testSelectionResetsCoalesceWindow() {
        var t = tracker()
        _ = t.recordOutput(at: 10.0, isSelected: false)
        t.recordSelected()
        XCTAssertTrue(t.recordOutput(at: 10.05, isSelected: false),
                      "fresh activity after selection publishes immediately")
    }
}
