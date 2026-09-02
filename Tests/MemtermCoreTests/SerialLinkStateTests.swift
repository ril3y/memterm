import XCTest
@testable import MemtermCore

// L1 (model truth): the serial link lifecycle machine — the founder
// disconnect/connect stage's core rule set. The one invariant that must
// never regress: a DELIBERATE user release suppresses hotplug auto-reopen
// (esptool/avrdude own the port until an explicit connect gesture), while a
// device-vanished loss keeps the tio-style auto-reopen armed.
final class SerialLinkStateTests: XCTestCase {

    func testInitialStateIsIdleWithNoStandingConsent() {
        let m = SerialLinkStateMachine()
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(m.isConnected)
        XCTAssertFalse(m.shouldAutoReopenOnHotplug,
                       "restore boundary must never auto-open")
        XCTAssertTrue(m.allowsConnectGesture)
    }

    func testConnectFromIdle() {
        var m = SerialLinkStateMachine()
        m.didConnect()
        XCTAssertEqual(m.state, .connected)
        XCTAssertTrue(m.isConnected)
        XCTAssertFalse(m.allowsConnectGesture)
        XCTAssertFalse(m.shouldAutoReopenOnHotplug)
    }

    func testUserDisconnectSuppressesHotplugAutoReopen() {
        var m = SerialLinkStateMachine()
        m.didConnect()
        m.userDisconnect()
        XCTAssertEqual(m.state, .userDisconnected)
        XCTAssertFalse(m.isConnected)
        XCTAssertFalse(m.shouldAutoReopenOnHotplug,
                       "a deliberate release must never steal the port back mid-flash")
        XCTAssertTrue(m.allowsConnectGesture)
    }

    func testDeviceLossArmsAutoReopen() {
        var m = SerialLinkStateMachine()
        m.didConnect()
        m.deviceLost()
        XCTAssertEqual(m.state, .reconnectingAfterLoss)
        XCTAssertFalse(m.isConnected)
        XCTAssertTrue(m.shouldAutoReopenOnHotplug,
                      "the original open is standing consent for a live-session return")
    }

    func testDeviceLossReportedAfterUserDisconnectDoesNotRearm() {
        // Drivers can race the user's close with a detach notification: the
        // loss report must not relabel the deliberate release.
        var m = SerialLinkStateMachine()
        m.didConnect()
        m.userDisconnect()
        m.deviceLost()
        XCTAssertEqual(m.state, .userDisconnected)
        XCTAssertFalse(m.shouldAutoReopenOnHotplug)
    }

    func testUserDisconnectWhileReconnectingCancelsTheArm() {
        var m = SerialLinkStateMachine()
        m.didConnect()
        m.deviceLost()
        m.userDisconnect()
        XCTAssertEqual(m.state, .userDisconnected)
        XCTAssertFalse(m.shouldAutoReopenOnHotplug)
    }

    func testUserDisconnectFromIdleIsANoOp() {
        // Nothing to release; idle's consent posture must not be relabeled.
        var m = SerialLinkStateMachine()
        m.userDisconnect()
        XCTAssertEqual(m.state, .idle)
    }

    func testDeviceLostFromIdleAndUserDisconnectedIsANoOp() {
        var idle = SerialLinkStateMachine()
        idle.deviceLost()
        XCTAssertEqual(idle.state, .idle)
    }

    func testReconnectFromUserDisconnected() {
        var m = SerialLinkStateMachine()
        m.didConnect()
        m.userDisconnect()
        m.didConnect()  // the explicit connect gesture, with current settings
        XCTAssertEqual(m.state, .connected)
        XCTAssertTrue(m.isConnected)
    }

    func testHotplugReturnReconnects() {
        var m = SerialLinkStateMachine()
        m.didConnect()
        m.deviceLost()
        m.didConnect()  // hotplugAttached funnels through the same connect()
        XCTAssertEqual(m.state, .connected)
    }

    // MARK: - Footer mapping (one machine state, one dot)

    func testFooterLinkStateMapping() {
        var m = SerialLinkStateMachine()
        XCTAssertEqual(SerialFooterModel.linkState(m), .disconnected)
        m.didConnect()
        XCTAssertEqual(SerialFooterModel.linkState(m), .connected)
        m.deviceLost()
        XCTAssertEqual(SerialFooterModel.linkState(m), .reconnecting)
        m.userDisconnect()
        XCTAssertEqual(SerialFooterModel.linkState(m), .userDisconnected)
    }

    func testDotGlyphHollowOnlyForUserDisconnect() {
        XCTAssertEqual(SerialFooterModel.dotGlyph(.connected), "●")
        XCTAssertEqual(SerialFooterModel.dotGlyph(.reconnecting), "●")
        XCTAssertEqual(SerialFooterModel.dotGlyph(.disconnected), "●")
        XCTAssertEqual(SerialFooterModel.dotGlyph(.userDisconnected), "○",
                       "the deliberate release must read distinct from the orange arm")
    }

    func testDotTooltipStatesTheAction() {
        XCTAssertEqual(SerialFooterModel.dotTooltip(.connected),
                       "Connected — click to disconnect")
        XCTAssertEqual(SerialFooterModel.dotTooltip(.userDisconnected),
                       "disconnected — click to connect")
        XCTAssertTrue(SerialFooterModel.dotTooltip(.reconnecting)
                        .contains("click to connect"))
        XCTAssertTrue(SerialFooterModel.dotTooltip(.disconnected)
                        .contains("click to connect"))
    }
}
