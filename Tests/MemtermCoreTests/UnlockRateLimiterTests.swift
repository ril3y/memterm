import XCTest
@testable import MemtermCore

// Remote-attach (decision doc 2026-09-19): unlocking a locked workspace from
// a phone client requires a passcode check on the Mac side. This sliding
// window limiter throttles guesses per device so a stolen/lost phone can't
// be used to brute-force the passcode.
final class UnlockRateLimiterTests: XCTestCase {
    func testAllowsUpToLimitThenRefusesWithinWindow() {
        var limiter = UnlockRateLimiter(limit: 5, window: 60)
        let device = "device-a"

        for i in 0..<5 {
            XCTAssertTrue(limiter.allow(deviceId: device, at: Double(i)), "attempt \(i) should be allowed")
        }
        XCTAssertFalse(limiter.allow(deviceId: device, at: 5), "6th attempt within the window should be refused")
    }

    func testAllowsAgainOnceOldestAttemptFallsOutOfWindow() {
        var limiter = UnlockRateLimiter(limit: 5, window: 60)
        let device = "device-a"

        for i in 0..<5 {
            XCTAssertTrue(limiter.allow(deviceId: device, at: Double(i))) // t = 0,1,2,3,4
        }
        XCTAssertFalse(limiter.allow(deviceId: device, at: 10))

        // The first attempt (t=0) is exactly 60s old at t=60: window boundary
        // is exclusive, so it has fallen out and a slot opens up.
        XCTAssertTrue(limiter.allow(deviceId: device, at: 60), "oldest attempt should have expired by t=60")

        // Immediately after, the window again holds 5 (t=1..4,60) so the
        // next attempt at the same instant is refused.
        XCTAssertFalse(limiter.allow(deviceId: device, at: 60))
    }

    func testWindowBoundaryIsExclusiveJustBeforeExpiry() {
        var limiter = UnlockRateLimiter(limit: 1, window: 60)
        let device = "device-a"

        XCTAssertTrue(limiter.allow(deviceId: device, at: 0))
        // Just under 60s later, the first attempt still counts.
        XCTAssertFalse(limiter.allow(deviceId: device, at: 59.999))
        // At exactly 60s later, the first attempt has aged out.
        XCTAssertTrue(limiter.allow(deviceId: device, at: 60))
    }

    func testDevicesAreIndependent() {
        var limiter = UnlockRateLimiter(limit: 2, window: 60)

        XCTAssertTrue(limiter.allow(deviceId: "device-a", at: 0))
        XCTAssertTrue(limiter.allow(deviceId: "device-a", at: 0))
        XCTAssertFalse(limiter.allow(deviceId: "device-a", at: 0))

        // device-b has its own independent budget.
        XCTAssertTrue(limiter.allow(deviceId: "device-b", at: 0))
        XCTAssertTrue(limiter.allow(deviceId: "device-b", at: 0))
        XCTAssertFalse(limiter.allow(deviceId: "device-b", at: 0))
    }

    func testDefaultLimitAndWindow() {
        var limiter = UnlockRateLimiter()
        let device = "device-a"

        for i in 0..<5 {
            XCTAssertTrue(limiter.allow(deviceId: device, at: Double(i)))
        }
        XCTAssertFalse(limiter.allow(deviceId: device, at: 5))
        XCTAssertTrue(limiter.allow(deviceId: device, at: 60))
    }
}
