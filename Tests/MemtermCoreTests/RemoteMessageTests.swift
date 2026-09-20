import XCTest
@testable import MemtermCore

// Remote-attach wire contract (Task 5, decision doc 2026-09-19): the inner
// RemoteMessage protocol and outer RemoteEnvelope are the JSON spoken between
// the phone client, the Node relay, and this host. The relay and a future
// TypeScript client parse the same bytes, so every tag and field name here is
// a cross-language contract — these tests pin the exact wire shape and the
// promise that decode() never traps on garbage.
final class RemoteMessageTests: XCTestCase {
    private func roundTrip(_ message: RemoteMessage, file: StaticString = #filePath, line: UInt = #line) {
        let data = message.encode()
        XCTAssertEqual(RemoteMessage.decode(data), message, file: file, line: line)
    }

    func testListRoundTrips() {
        roundTrip(.list)
    }

    func testAttachRoundTrips() {
        roundTrip(.attach(paneId: "pane-1"))
    }

    func testDetachRoundTrips() {
        roundTrip(.detach)
    }

    func testInputRoundTrips() {
        roundTrip(.input(Data([0x1b, 0x5b, 0x41, 0x00, 0xff])))
    }

    func testResizeRoundTrips() {
        roundTrip(.resize(cols: 120, rows: 40))
    }

    func testNewTabRoundTrips() {
        roundTrip(.newTab(workspaceId: "ws-1"))
    }

    func testUnlockRoundTrips() {
        roundTrip(.unlock(workspaceId: "ws-1", passphrase: "hunter2"))
    }

    func testTreeRoundTrips() {
        let pane = RemotePane(id: "p1", adapter: "shell", cwd: "/tmp")
        let tab = RemoteTab(id: "t1", title: "bash", panes: [pane])
        let window = RemoteWindow(id: "w1", tabs: [tab])
        let workspace = RemoteWorkspace(id: "ws1", name: "Default", color: "blue", locked: false, parked: false, windows: [window])
        roundTrip(.tree(RemoteTree(workspaces: [workspace])))
    }

    func testScreenRoundTrips() {
        roundTrip(.screen(cols: 80, rows: 24, bytes: Data([1, 2, 3, 250, 255])))
    }

    func testOutputRoundTrips() {
        roundTrip(.output(Data("hello".utf8)))
    }

    func testTreeChangedRoundTrips() {
        roundTrip(.treeChanged)
    }

    func testRefusedRoundTrips() {
        roundTrip(.refused(reason: "locked"))
    }

    func testResizedRoundTrips() {
        roundTrip(.resized(cols: 100, rows: 30))
    }

    /// An unknown tag must decode to nil, never crash — the relay forwards
    /// bytes it never validates, so a future/foreign message tag must fail
    /// closed on this side.
    func testUnknownTagDecodesToNil() {
        let data = Data(#"{"t":"bogus"}"#.utf8)
        XCTAssertNil(RemoteMessage.decode(data))
    }

    func testGarbageJSONDecodesToNil() {
        let data = Data("not json".utf8)
        XCTAssertNil(RemoteMessage.decode(data))
    }

    /// "attach" without paneId must fail closed, not crash.
    func testMissingRequiredFieldDecodesToNil() {
        let data = Data(#"{"t":"attach"}"#.utf8)
        XCTAssertNil(RemoteMessage.decode(data))
    }

    func testInvalidBase64DecodesToNil() {
        let data = Data(#"{"t":"input","b":"not-valid-base64!!"}"#.utf8)
        XCTAssertNil(RemoteMessage.decode(data))
    }

    /// Binary bytes across the full byte range must survive base64
    /// round-tripping intact — the wire is JSON, so raw bytes can never
    /// appear un-encoded, and the tag key stays "b" per the brief.
    func testInputBytesSurviveBase64Roundtrip() {
        var bytes = [UInt8]()
        for value in 0...255 { bytes.append(UInt8(value)) }
        let message = RemoteMessage.input(Data(bytes))
        let data = message.encode()
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\"b\"") ?? false)
        XCTAssertEqual(RemoteMessage.decode(data), message)
    }
}

final class RemoteEnvelopeTests: XCTestCase {
    func testRoundTrips() {
        let envelope = RemoteEnvelope(to: "host-1", from: "phone-1", payload: Data("secret".utf8))
        let data = envelope.encode()
        XCTAssertEqual(RemoteEnvelope.decode(data), envelope)
    }

    /// The relay routes purely on `to`; an envelope missing it can never be
    /// forwarded, so decode must reject it rather than default to empty.
    func testMissingToDecodesToNil() {
        let data = Data(#"{"type":"env","from":"phone-1","payload":"AAAA"}"#.utf8)
        XCTAssertNil(RemoteEnvelope.decode(data))
    }

    func testWrongTypeDecodesToNil() {
        let data = Data(#"{"type":"other","to":"a","from":"b","payload":"AAAA"}"#.utf8)
        XCTAssertNil(RemoteEnvelope.decode(data))
    }
}
