import CoreGraphics
import XCTest
@testable import MemtermCore

// FR-59 pure logic: resurrect-path frame placement (windows never jump; only
// fully off-screen frames get adjusted) and the MRU hidden-workspace pick for
// the last-visible-window corollary.

final class SwitchSupportTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: adjustedFrame — frame stability

    func testOnScreenFrameIsUntouched() {
        let frame = CGRect(x: 100, y: 100, width: 980, height: 640)
        XCTAssertEqual(SwitchSupport.adjustedFrame(frame, visibleFrames: [screen]), frame)
    }

    func testPartiallyOffScreenFrameIsUntouched() {
        // FR-59: only a frame that lands FULLY off-screen is adjusted — a
        // deliberately half-off window stays exactly where the user left it.
        let frame = CGRect(x: -400, y: 700, width: 980, height: 640)
        XCTAssertEqual(SwitchSupport.adjustedFrame(frame, visibleFrames: [screen]), frame)
    }

    func testFrameOnSecondScreenIsUntouched() {
        let second = CGRect(x: 1440, y: 0, width: 2560, height: 1440)
        let frame = CGRect(x: 1800, y: 200, width: 980, height: 640)
        XCTAssertEqual(SwitchSupport.adjustedFrame(frame, visibleFrames: [screen, second]),
                       frame, "a frame on an attached display must not move")
    }

    func testFullyOffScreenFrameMovesOntoFirstScreen() {
        // The classic case: monitor unplugged since capture.
        let frame = CGRect(x: 3000, y: 200, width: 980, height: 640)
        let adjusted = SwitchSupport.adjustedFrame(frame, visibleFrames: [screen])
        XCTAssertTrue(screen.contains(adjusted), "adjusted frame must land on-screen")
        XCTAssertEqual(adjusted.size, frame.size, "size survives when it fits")
        // Clamped to the near edge, not centered or cascaded.
        XCTAssertEqual(adjusted.origin.x, screen.maxX - frame.width)
        XCTAssertEqual(adjusted.origin.y, 200)
    }

    func testOffScreenInEveryDirectionClampsInside() {
        for origin in [CGPoint(x: -2000, y: 300), CGPoint(x: 300, y: -2000),
                       CGPoint(x: 300, y: 2000), CGPoint(x: -2000, y: -2000)] {
            let frame = CGRect(origin: origin, size: CGSize(width: 500, height: 400))
            let adjusted = SwitchSupport.adjustedFrame(frame, visibleFrames: [screen])
            XCTAssertTrue(screen.contains(adjusted), "origin \(origin) must clamp on-screen")
        }
    }

    func testOversizedOffScreenFrameShrinksToScreen() {
        let frame = CGRect(x: 5000, y: 5000, width: 3000, height: 2000)
        let adjusted = SwitchSupport.adjustedFrame(frame, visibleFrames: [screen])
        XCTAssertEqual(adjusted, screen, "bigger than the screen: fill it, never overflow")
    }

    func testNoScreensPassesFrameThrough() {
        // Headless: no basis for adjustment, never mangle the journaled frame.
        let frame = CGRect(x: 9999, y: 9999, width: 980, height: 640)
        XCTAssertEqual(SwitchSupport.adjustedFrame(frame, visibleFrames: []), frame)
    }

    // MARK: mruPick — surface the most recently used hidden workspace

    func testPicksMostRecentCandidate() {
        XCTAssertEqual(SwitchSupport.mruPick(candidates: ["a", "b", "c"],
                                             mostRecentFirst: ["b", "a"]), "b")
    }

    func testSkipsMruEntriesThatAreNotCandidates() {
        // "z" was switched away from most recently but has no live windows
        // any more (parked/forgotten) — it must be skipped, not surfaced.
        XCTAssertEqual(SwitchSupport.mruPick(candidates: ["a", "c"],
                                             mostRecentFirst: ["z", "c", "a"]), "c")
    }

    func testFallsBackDeterministicallyWithoutHistory() {
        XCTAssertEqual(SwitchSupport.mruPick(candidates: ["c", "a", "b"],
                                             mostRecentFirst: []), "a")
        XCTAssertEqual(SwitchSupport.mruPick(candidates: ["c", "a"],
                                             mostRecentFirst: ["nope"]), "a")
    }

    func testNilWhenNoCandidates() {
        XCTAssertNil(SwitchSupport.mruPick(candidates: [], mostRecentFirst: ["a"]))
    }
}
