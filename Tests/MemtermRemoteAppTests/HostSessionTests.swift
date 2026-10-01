import XCTest
import MemtermRemoteKit
import MemtermRemoteKitTesting
@testable import MemtermRemoteApp

@MainActor
final class HostSessionTests: XCTestCase {
    private var factory: FakeTransportFactory!
    private var scheduler: FakeScheduler!
    private var hostIdentity: RemoteIdentity!     // stands in for the Mac
    private var phoneIdentity: RemoteIdentity!
    private var paired: PairedHost!
    private var session: HostSession!
    private var output: [Data] = []
    /// The session's clock, for the `online` restart throttle and the
    /// `lastSeen` sanity bound. A test moves it rather than sleeping.
    private var clock = Date()

    override func setUp() async throws {
        try await super.setUp()
        factory = FakeTransportFactory(); scheduler = FakeScheduler()
        hostIdentity = RemoteIdentity.generate(); phoneIdentity = RemoteIdentity.generate()
        output = []
        clock = Date()
        paired = PairedHost(id: hostIdentity.id, publicKeySPKI: hostIdentity.publicKeySPKI,
                            relay: URL(string: "wss://relay.example.test")!,
                            name: "Mac mini", pairedAt: Date())
        // The same `scheduler` backs the connection's reconnect/ping timers
        // and the session's own handshake timeout, so `scheduler.fire(delay:)`
        // is how a test names which of them it means.
        session = HostSession(
            host: paired, signer: phoneIdentity,
            makeConnection: { [self] url, events in
                RelayConnection(base: url, role: .client, signer: phoneIdentity, events: events,
                                transports: factory, schedule: { [self] d, b in scheduler.schedule(d, b) })
            },
            schedule: { [self] d, b in scheduler.schedule(d, b) },
            now: { [self] in clock })
        session.onOutput = { [self] in output.append($0) }
    }

    // -- helpers: drive the relay and the Mac by hand ----------------------

    private func authenticate() {
        factory.current.push(["type": "challenge",
                              "nonce": Data(repeating: 3, count: 32).base64EncodedString()])
        factory.current.push(["type": "authed", "id": phoneIdentity.id])
    }

    /// The Mac's side of the handshake: read the phone's Hello off the wire,
    /// answer with ours, and return the session keys the Mac would hold.
    /// `forHelloAt` picks which sent Hello to answer (Python-style negative
    /// indices; the default, -1, is the most recent) — when a reconnect
    /// sends a second Hello before the first is answered, a test needs to
    /// address either one.
    private func completeHandshake(forHelloAt index: Int = -1) throws -> RemoteSessionKeys {
        let hellos = factory.current.sentEnvelopes
        let sent = hellos[index >= 0 ? index : hellos.count + index]
        let theirHello = try XCTUnwrap(HelloWire.decode(sent.payload))
        let (mine, ephemeral) = try RemoteHandshake.makeHello(signer: hostIdentity)
        let keys = try RemoteHandshake.deriveKeys(myEphemeral: ephemeral,
                                                  peerEphemeralRaw: theirHello.ephemeralRaw,
                                                  hostId: hostIdentity.id,
                                                  deviceId: phoneIdentity.id,
                                                  iAmHost: true)
        factory.current.push(["type": "env", "to": phoneIdentity.id, "from": hostIdentity.id,
                              "payload": HelloWire.encode(mine).base64EncodedString()])
        return keys
    }

    private func send(_ message: RemoteMessage, with keys: RemoteSessionKeys) throws {
        let sealed = try keys.seal(message.encode())
        factory.current.push(["type": "env", "to": phoneIdentity.id, "from": hostIdentity.id,
                              "payload": sealed.base64EncodedString()])
    }

    private func tree(panes: [String]) -> RemoteTree {
        RemoteTree(workspaces: [
            RemoteWorkspace(id: "w1", name: "Default", color: "#888888", locked: false, parked: false,
                            windows: [RemoteWindow(id: "win1", tabs: [
                                RemoteTab(id: "t1", title: "zsh",
                                          panes: panes.map { RemotePane(id: $0, adapter: "shell", cwd: "/tmp") })
                            ])])
        ])
    }

    // -- the tests ---------------------------------------------------------

    func testStartHandshakesListsAndBecomesReady() throws {
        session.start()
        XCTAssertEqual(session.phase, .connecting)
        authenticate()
        XCTAssertEqual(session.phase, .handshaking)
        let keys = try completeHandshake()
        // The phone asks for the tree as soon as it has keys.
        XCTAssertEqual(try keys.open(factory.current.sentEnvelopes.last!.payload),
                       RemoteMessage.list.encode())
        try send(.tree(tree(panes: ["p1"])), with: keys)
        XCTAssertEqual(session.phase, .ready)
        XCTAssertEqual(ViewerTree.rows(from: try XCTUnwrap(session.tree)).map(\.id), ["p1"])
    }

    func testAttachDeliversScreenThenOutput() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        session.attach(paneId: "p1")
        try send(.screen(cols: 80, rows: 24, bytes: Data("hello".utf8)), with: keys)
        XCTAssertEqual(session.phase, .attached(paneId: "p1"))
        XCTAssertEqual(output, [Data("hello".utf8)])
        try send(.output(Data(" world".utf8)), with: keys)
        XCTAssertEqual(output.map { String(decoding: $0, as: UTF8.self) }, ["hello", " world"])
    }

    func testTypingSealsInputInOrder() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        session.attach(paneId: "p1")
        session.input(Data("a".utf8)); session.input(Data("b".utf8))
        // The Mac opens every record in order — its receive counter is exact
        // — so a test that read only the last two would see them as a replay.
        // Index 0 is the clear-text Hello, which is not a sealed record.
        let opened = try factory.current.sentEnvelopes.dropFirst().map { try keys.open($0.payload) }
        // Compare DECODED messages, not encoded bytes: what this test means
        // is "these two messages, in this order", and comparing serialized
        // forms would also be asserting a byte layout no one promised.
        XCTAssertEqual(opened.suffix(2).compactMap(RemoteMessage.decode),
                       [.input(Data("a".utf8)), .input(Data("b".utf8))],
                       "records arrive in the order they were sealed")
    }

    func testAttachedPaneVanishingReturnsToTree() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        session.attach(paneId: "p1")
        try send(.screen(cols: 80, rows: 24, bytes: Data()), with: keys)
        // The Mac closed the pane: tree-changed, then a tree without it.
        try send(.treeChanged, with: keys)
        try send(.tree(tree(panes: ["p2"])), with: keys)
        XCTAssertEqual(session.phase, .ready, "a vanished pane drops the viewer back to the tree")
    }

    func testAReplyToASupersededHandshakeIsDroppedWhileTheLiveOneSucceeds() throws {
        session.start()
        factory.current.push(["type": "challenge", "nonce": Data(repeating: 3, count: 32).base64EncodedString()])
        factory.current.push(["type": "authed", "id": phoneIdentity.id])
        // A reconnect: the relay authenticates us again with no start() in
        // between, so a second Hello goes out while the first is still in
        // flight. Two ephemerals now exist; only the newer one is live.
        factory.current.push(["type": "authed", "id": phoneIdentity.id])
        let hellos = factory.current.sentEnvelopes
        XCTAssertEqual(hellos.count, 2, "each authed sends its own Hello")

        // The Mac answers the SUPERSEDED Hello first. Derive against it, so
        // the reply is cryptographically valid — only its generation is stale.
        let stale = try completeHandshake(forHelloAt: 0)
        XCTAssertEqual(session.phase, .handshaking, "a stale reply must not open a session")
        try send(.tree(tree(panes: ["p1"])), with: stale)
        XCTAssertNil(session.tree, "nothing sealed under the superseded keys is read")

        // Then it answers the live one.
        let live = try completeHandshake(forHelloAt: 1)
        try send(.tree(tree(panes: ["p1"])), with: live)
        XCTAssertEqual(session.phase, .ready)
    }

    func testForegroundReattachesWhenThePaneSurvives() throws {
        session.start(); authenticate()
        var keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        session.attach(paneId: "p1")
        try send(.screen(cols: 80, rows: 24, bytes: Data()), with: keys)
        session.sceneWentToBackground()
        XCTAssertEqual(session.phase, .idle)
        session.sceneBecameActive()
        authenticate()
        keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        XCTAssertEqual(session.phase, .attached(paneId: "p1"), "re-attaches to the same pane")
    }

    func testForegroundFallsBackToTreeWhenItDoesNot() throws {
        session.start(); authenticate()
        var keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        session.attach(paneId: "p1")
        try send(.screen(cols: 80, rows: 24, bytes: Data()), with: keys)
        session.sceneWentToBackground()
        session.sceneBecameActive()
        authenticate()
        keys = try completeHandshake()
        try send(.tree(tree(panes: ["p2"])), with: keys)
        XCTAssertEqual(session.phase, .ready)
    }

    func testHostOfflineIsSurfaced() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        factory.current.push(["type": "offline", "hostId": hostIdentity.id,
                              "lastSeen": Date().timeIntervalSince1970 * 1000])
        guard case .offline = session.phase else {
            return XCTFail("expected .offline, got \(session.phase)")
        }
    }

    func testRevokedMidSessionIsSurfaced() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        session.attach(paneId: "p1")
        factory.current.push(["type": "refused", "reason": "not-allowed"])
        guard case .failed(let message) = session.phase else {
            return XCTFail("expected .failed, got \(session.phase)")
        }
        XCTAssertTrue(message.lowercased().contains("no longer"), "says the Mac revoked us: \(message)")
    }

    func testAnUnopenableRecordIsIgnoredAndTheMacsNextRecordStillOpens() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        // A record sealed under the wrong keys: the counter/tag check fails.
        // `RemoteSessionKeys`' own initializer is internal to the kit (keys
        // are only ever meant to come out of a handshake), so the "wrong
        // keys" stand-in is itself derived, from an unrelated shared secret.
        // Such a record cannot have come from the paired Mac, so the session
        // ignores it: ending here would let one injected frame from a hostile
        // relay deny service, and the kit does not advance the receive counter
        // on a failed open precisely so the genuine next record still opens.
        let wrong = RemoteHandshake.deriveKeys(sharedSecret: Data(repeating: 9, count: 32),
                                               hostId: "wrong-host", deviceId: "wrong-device", iAmHost: true)
        factory.current.push(["type": "env", "to": phoneIdentity.id, "from": hostIdentity.id,
                              "payload": try wrong.seal(RemoteMessage.treeChanged.encode()).base64EncodedString()])
        XCTAssertEqual(session.phase, .ready, "one injected record must not end the session")
        try send(.tree(tree(panes: ["p1", "p2"])), with: keys)
        XCTAssertEqual(ViewerTree.rows(from: try XCTUnwrap(session.tree)).map(\.id), ["p1", "p2"],
                       "the Mac's real next record still opens")
    }

    // -- the Mac's refusals: one request refused, never a dead session ------

    /// Attached to "p1", with the Mac's keys in hand, ready for a `refused`.
    private func attachedSession() throws -> RemoteSessionKeys {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        session.attach(paneId: "p1")
        try send(.screen(cols: 80, rows: 24, bytes: Data()), with: keys)
        return keys
    }

    /// Every sealed record the phone has sent, opened in order — the Mac's
    /// receive counter is exact, so they can only be read all or none.
    private func sentMessages(with keys: RemoteSessionKeys) throws -> [RemoteMessage] {
        try factory.current.sentEnvelopes.dropFirst().map { try keys.open($0.payload) }
            .compactMap(RemoteMessage.decode)
    }

    func testRefusedUnknownPaneReturnsToTheTreeAndAsksForAFreshOne() throws {
        let keys = try attachedSession()
        try send(.refused(reason: "unknown-pane"), with: keys)
        XCTAssertEqual(session.phase, .ready, "the pane is gone: back to the tree, not a dead terminal")
        XCTAssertNil(session.notice, "TreeView's own closed-pane notice covers this one")
        XCTAssertEqual(try sentMessages(with: keys).last, .list, "and it asks what is open now")
    }

    func testRefusedLockedSaysSoAndKeepsTheSession() throws {
        let keys = try attachedSession()
        try send(.refused(reason: "locked"), with: keys)
        XCTAssertEqual(session.phase, .ready)
        let notice = try XCTUnwrap(session.notice)
        XCTAssertTrue(notice.contains("locked"), "says what happened: \(notice)")
        XCTAssertTrue(notice.contains("Mac mini"), "and where: \(notice)")
    }

    func testRefusedUnsupportedSaysSoInWordsNotTheProtocolToken() throws {
        let keys = try attachedSession()
        try send(.refused(reason: "unsupported"), with: keys)
        XCTAssertEqual(session.phase, .ready)
        let notice = try XCTUnwrap(session.notice)
        XCTAssertFalse(notice.contains("unsupported"), "not the wire word: \(notice)")
        XCTAssertTrue(notice.contains("attach"), "but it does say what failed: \(notice)")
    }

    func testAnUnknownRefusalReasonIsNeitherFatalNorShownVerbatim() throws {
        let keys = try attachedSession()
        // A real Mac reason this client does not provoke today
        // (`RemoteHost+Dispatch.swift` sends it for `unlock`), standing in for
        // any reason a later Mac might add.
        try send(.refused(reason: "rate-limited"), with: keys)
        XCTAssertEqual(session.phase, .ready, "a refused request is not a lost session")
        let notice = try XCTUnwrap(session.notice)
        XCTAssertFalse(notice.contains("rate-limited"), "machine vocabulary stays off screen: \(notice)")
    }

    // -- the connection's own story ----------------------------------------

    func testAnUnreachableRelayIsSurfacedAndThenRecoversOnItsOwn() throws {
        session.start()
        XCTAssertEqual(session.phase, .connecting)
        factory.current.fail("The Internet connection appears to be offline.")
        guard case .unreachable = session.phase else {
            return XCTFail("expected .unreachable, got \(session.phase)")
        }
        // The kit retries with 1 s backoff; the session is a status report on
        // that, not a dead end.
        XCTAssertTrue(scheduler.fire(delay: 1), "the connection armed its reconnect")
        XCTAssertEqual(session.phase, .connecting)
        authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        XCTAssertEqual(session.phase, .ready, "the reconnect completes a real handshake")
    }

    func testAHelloTheMacNeverAnswersStopsBeingASpinner() throws {
        session.start(); authenticate()
        XCTAssertEqual(session.phase, .handshaking)
        XCTAssertTrue(scheduler.fire(delay: HostSession.handshakeTimeout),
                      "the handshake armed its timeout")
        XCTAssertEqual(session.phase, .offline(since: nil),
                       "the relay authenticated us, so the Mac is what is not answering")
    }

    func testTheHandshakeTimeoutDoesNotFireOnASessionThatCompleted() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        XCTAssertFalse(scheduler.fire(delay: HostSession.handshakeTimeout),
                       "a completed handshake cancels its own timeout")
        XCTAssertEqual(session.phase, .ready)
    }

    func testAnUnverifiableHelloIsIgnoredAndTheGenuineReplyStillLands() throws {
        session.start(); authenticate()
        // The relay chooses `from`, so it can claim to be the Mac. This Hello
        // is well-formed and signed — by somebody else.
        let impostor = RemoteIdentity.generate()
        let (forged, _) = try RemoteHandshake.makeHello(signer: impostor)
        factory.current.push(["type": "env", "to": phoneIdentity.id, "from": hostIdentity.id,
                              "payload": HelloWire.encode(forged).base64EncodedString()])
        XCTAssertEqual(session.phase, .handshaking,
                       "an injected Hello neither ends the handshake nor accuses the Mac")
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        XCTAssertEqual(session.phase, .ready, "the live ephemeral was not spent on the forgery")
    }

    func testAnOnlineFrameDoesNotTearDownALiveSession() throws {
        _ = try attachedSession()
        let connections = factory.made.count
        factory.current.push(["type": "online", "hostId": hostIdentity.id])
        XCTAssertEqual(session.phase, .attached(paneId: "p1"), "a working session is left alone")
        XCTAssertEqual(factory.made.count, connections, "and nothing reconnects behind it")
    }

    func testOnlineForAnotherMacIsIgnoredAndOurOwnRestartIsThrottled() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        factory.current.push(["type": "offline", "hostId": hostIdentity.id])
        guard case .offline = session.phase else {
            return XCTFail("expected .offline, got \(session.phase)")
        }
        var connections = factory.made.count
        factory.current.push(["type": "online", "hostId": "some-other-mac"])
        guard case .offline = session.phase else {
            return XCTFail("another Mac's frame moved this session")
        }
        XCTAssertEqual(factory.made.count, connections, "another Mac's frame reconnects nothing")

        factory.current.push(["type": "online", "hostId": hostIdentity.id])
        XCTAssertEqual(session.phase, .connecting, "our own Mac coming back does restart")
        XCTAssertEqual(factory.made.count, connections + 1)

        // Back to offline, then a second `online` straight away: a relay must
        // not be able to drive a reconnect loop, since each one makes the Mac
        // run `endSession`.
        factory.current.push(["type": "offline", "hostId": hostIdentity.id])
        connections = factory.made.count
        factory.current.push(["type": "online", "hostId": hostIdentity.id])
        XCTAssertEqual(factory.made.count, connections, "a repeat inside the window is ignored")
        clock = clock.addingTimeInterval(HostSession.onlineRestartInterval + 1)
        factory.current.push(["type": "online", "hostId": hostIdentity.id])
        XCTAssertEqual(factory.made.count, connections + 1, "and allowed again once the window passes")
    }

    func testOfflineForAnotherMacIsIgnored() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        factory.current.push(["type": "offline", "hostId": "some-other-mac",
                              "lastSeen": clock.timeIntervalSince1970 * 1000])
        XCTAssertEqual(session.phase, .ready, "this session only reports on its own Mac")
    }

    func testAnImplausibleLastSeenIsNotPutInASentence() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        // Year 5138, from a relay that is hostile by assumption.
        factory.current.push(["type": "offline", "hostId": hostIdentity.id,
                              "lastSeen": 99_999_999_999_999 as Double])
        XCTAssertEqual(session.phase, .offline(since: nil),
                       "an impossible date is dropped rather than formatted")
    }

    func testARelayRefusalOtherThanRevocationIsNotShownVerbatim() throws {
        session.start(); authenticate()
        factory.current.push(["type": "refused", "reason": "<b>call 555-0100</b>"])
        guard case .failed(let message) = session.phase else {
            return XCTFail("expected .failed, got \(session.phase)")
        }
        XCTAssertFalse(message.contains("555-0100"), "relay-chosen text stays off screen: \(message)")
    }

    func testBackgroundingForgetsTheTree() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        XCTAssertNotNil(session.tree)
        session.sceneWentToBackground()
        XCTAssertNil(session.tree, "a stale tree must not be rendered on the way back in")
    }
}
