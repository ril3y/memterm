import XCTest
@testable import MemtermCore

// FR-18 (boot-session discrimination) and FR-36/§9 (one --resume <uuid> per
// pane) — the pure halves of the restore pipeline's launch classification and
// duplicate-session dedupe.

final class RestoreSupportTests: XCTestCase {

    // MARK: BootSession (FR-18)

    func testLaunchKindDiscriminatesRebootFromAppRestart() {
        XCTAssertEqual(BootSession.launchKind(storedBootUUID: "A", liveBootUUID: "A"),
                       .sameBoot)
        XCTAssertEqual(BootSession.launchKind(storedBootUUID: "A", liveBootUUID: "B"),
                       .reboot)
        XCTAssertEqual(BootSession.launchKind(storedBootUUID: nil, liveBootUUID: "B"),
                       .firstRun)
        XCTAssertEqual(BootSession.launchKind(storedBootUUID: "", liveBootUUID: "B"),
                       .firstRun)
        // sysctl failure cannot discriminate — conservatively an app restart.
        XCTAssertEqual(BootSession.launchKind(storedBootUUID: "A", liveBootUUID: nil),
                       .sameBoot)
    }

    // MARK: ClaudeSessionClaims (FR-36 / §9)

    func testSameUUIDIsNeverClaimedByTwoPanes() {
        let claims = ClaudeSessionClaims()
        XCTAssertTrue(claims.claim(sessionId: "uuid-1", paneId: "paneA"))
        XCTAssertFalse(claims.claim(sessionId: "uuid-1", paneId: "paneB"),
                       "second pane must be told to downgrade to --continue")
        XCTAssertEqual(claims.owner(of: "uuid-1"), "paneA")
        // Re-claim by the owner is idempotent (restore paths may re-evaluate).
        XCTAssertTrue(claims.claim(sessionId: "uuid-1", paneId: "paneA"))
        // A different UUID is independent.
        XCTAssertTrue(claims.claim(sessionId: "uuid-2", paneId: "paneB"))
    }

    func testReleaseFreesTheUUIDForALaterPane() {
        let claims = ClaudeSessionClaims()
        XCTAssertTrue(claims.claim(sessionId: "uuid-1", paneId: "paneA"))
        claims.release(paneId: "paneA")
        XCTAssertNil(claims.owner(of: "uuid-1"))
        // Workspace reopened later: a new pane may claim the freed UUID.
        XCTAssertTrue(claims.claim(sessionId: "uuid-1", paneId: "paneC"))
    }

    func testReleaseOnlyDropsTheClosingPanesClaims() {
        let claims = ClaudeSessionClaims()
        _ = claims.claim(sessionId: "uuid-1", paneId: "paneA")
        _ = claims.claim(sessionId: "uuid-2", paneId: "paneB")
        claims.release(paneId: "paneA")
        XCTAssertEqual(claims.owner(of: "uuid-2"), "paneB")
        XCTAssertFalse(claims.claim(sessionId: "uuid-2", paneId: "paneC"))
    }
}
