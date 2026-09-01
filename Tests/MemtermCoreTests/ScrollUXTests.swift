import XCTest
@testable import MemtermCore

// SCROLL UX stage — L1/L2 tests for the pure seams behind the overlay
// scrollbar and the selection-preservation predicate (TESTING.md §1
// placement rule: logic that can be a pure function is tested here; the
// AppKit faces are certified by the probe legs).

final class ScrollUXTests: XCTestCase {

    // MARK: MouseReportingPolicy

    func testMouseReportingOffWhileNoAppTracksTheMouse() {
        // The founder bug: allowMouseReporting=true (the config default) made
        // SwiftTerm clear the selection on every output chunk. The effective
        // flag must stay false until an app actually enables tracking.
        XCTAssertFalse(MouseReportingPolicy.effectiveAllowMouseReporting(
            configured: true, mouseModeActive: false))
        XCTAssertTrue(MouseReportingPolicy.effectiveAllowMouseReporting(
            configured: true, mouseModeActive: true))
    }

    func testMouseReportingNeverOnWhenConfigDisablesIt() {
        XCTAssertFalse(MouseReportingPolicy.effectiveAllowMouseReporting(
            configured: false, mouseModeActive: true))
        XCTAssertFalse(MouseReportingPolicy.effectiveAllowMouseReporting(
            configured: false, mouseModeActive: false))
    }

    // MARK: OverlayScrollerLayout — knob geometry

    private func metrics(track: CGFloat = 400, proportion: CGFloat,
                         position: CGFloat) -> OverlayScrollerMetrics {
        OverlayScrollerMetrics(trackLength: track, proportion: proportion,
                               position: position)
    }

    func testKnobProportionalToVisibleContent() throws {
        let m = metrics(proportion: 0.5, position: 0)
        let knob = try XCTUnwrap(OverlayScrollerLayout.knob(m))
        let usable = 400 - 2 * OverlayScrollerLayout.endInset
        XCTAssertEqual(knob.length, (usable * 0.5).rounded())
        XCTAssertEqual(knob.offset, OverlayScrollerLayout.endInset)
    }

    func testKnobNeverShrinksBelowMinimum() throws {
        let m = metrics(proportion: 0.001, position: 1)
        let knob = try XCTUnwrap(OverlayScrollerLayout.knob(m))
        XCTAssertEqual(knob.length, OverlayScrollerLayout.minKnobLength)
        // position 1 → knob flush with the bottom inset.
        let usable = 400 - 2 * OverlayScrollerLayout.endInset
        XCTAssertEqual(knob.offset,
                       OverlayScrollerLayout.endInset + usable - knob.length,
                       accuracy: 0.001)
    }

    func testKnobPositionInterpolatesAlongTravel() throws {
        let m = metrics(proportion: 0.25, position: 0.5)
        let knob = try XCTUnwrap(OverlayScrollerLayout.knob(m))
        let usable = 400 - 2 * OverlayScrollerLayout.endInset
        let travel = usable - knob.length
        XCTAssertEqual(knob.offset,
                       OverlayScrollerLayout.endInset + travel * 0.5,
                       accuracy: 0.001)
    }

    func testTinyTrackYieldsNoKnob() {
        XCTAssertNil(OverlayScrollerLayout.knob(
            metrics(track: 20, proportion: 0.5, position: 0)))
    }

    func testPositionClampsOutOfRangeInputs() throws {
        let m = metrics(proportion: 2.0, position: 7)
        let knob = try XCTUnwrap(OverlayScrollerLayout.knob(m))
        // proportion clamps to 1 → knob fills the usable track, position
        // clamps to 1 with zero travel.
        XCTAssertEqual(knob.length, 400 - 2 * OverlayScrollerLayout.endInset)
        XCTAssertEqual(knob.offset, OverlayScrollerLayout.endInset)
    }

    // MARK: drag mapping (round trip)

    func testDragRoundTripRecoversPosition() throws {
        let m = metrics(proportion: 0.2, position: 0.37)
        let knob = try XCTUnwrap(OverlayScrollerLayout.knob(m))
        let recovered = OverlayScrollerLayout.position(forKnobOffset: knob.offset,
                                                       metrics: m)
        XCTAssertEqual(recovered, 0.37, accuracy: 0.001)
    }

    func testDragClampsAtTrackEnds() {
        let m = metrics(proportion: 0.2, position: 0.5)
        XCTAssertEqual(OverlayScrollerLayout.position(forKnobOffset: -100, metrics: m), 0)
        XCTAssertEqual(OverlayScrollerLayout.position(forKnobOffset: 10_000, metrics: m), 1)
    }

    // MARK: track clicks page

    func testTrackClickAboveKnobPagesUpBelowPagesDown() throws {
        let m = metrics(proportion: 0.2, position: 0.5)
        let knob = try XCTUnwrap(OverlayScrollerLayout.knob(m))
        XCTAssertEqual(OverlayScrollerLayout.trackClick(at: knob.offset - 5, metrics: m),
                       .pageUp)
        XCTAssertEqual(OverlayScrollerLayout.trackClick(at: knob.offset + knob.length + 5,
                                                        metrics: m),
                       .pageDown)
        XCTAssertNil(OverlayScrollerLayout.trackClick(at: knob.offset + knob.length / 2,
                                                      metrics: m),
                     "a click on the knob is a drag, not a page")
    }

    // MARK: visibility state machine (injected clock)

    func testBarHiddenUntilFirstActivityThenFadesAfterDelay() {
        var v = OverlayScrollerVisibility(fadeDelay: 1.0)
        XCTAssertFalse(v.visible(now: 100))
        XCTAssertNil(v.nextFadeDeadline(now: 100))
        v.noteActivity(now: 100)
        XCTAssertTrue(v.visible(now: 100.5))
        XCTAssertEqual(v.nextFadeDeadline(now: 100.5), 101.0)
        XCTAssertFalse(v.visible(now: 101.1))
        XCTAssertNil(v.nextFadeDeadline(now: 101.1))
    }

    func testActivityExtendsTheFadeDeadline() {
        var v = OverlayScrollerVisibility(fadeDelay: 1.0)
        v.noteActivity(now: 100)
        v.noteActivity(now: 100.9)
        XCTAssertTrue(v.visible(now: 101.5))
        XCTAssertEqual(v.nextFadeDeadline(now: 101.5), 101.9)
    }

    func testDragAndHoverPinTheBarVisible() {
        var v = OverlayScrollerVisibility(fadeDelay: 1.0)
        v.noteActivity(now: 100)
        v.isDragging = true
        XCTAssertTrue(v.visible(now: 500))
        XCTAssertNil(v.nextFadeDeadline(now: 500), "no timed fade while dragging")
        v.isDragging = false
        v.isHovering = true
        XCTAssertTrue(v.visible(now: 500))
        v.isHovering = false
        XCTAssertFalse(v.visible(now: 500))
    }
}
