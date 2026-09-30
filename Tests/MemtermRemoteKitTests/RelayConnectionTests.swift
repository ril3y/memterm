import XCTest
@testable import MemtermRemoteKit

final class RelayConnectionTests: XCTestCase {
    private var factory: FakeTransportFactory!
    private var scheduler: FakeScheduler!
    private var states: [RelayConnection.State] = []
    private var controls: [[String: Any]] = []
    private var envelopes: [RemoteEnvelope] = []
    private var identity: RemoteIdentity!

    override func setUp() {
        super.setUp()
        factory = FakeTransportFactory(); scheduler = FakeScheduler()
        states = []; controls = []; envelopes = []
        identity = RemoteIdentity.generate()   // fresh P-256 key
    }

    private func make(role: RelayConnection.Role = .client,
                      extra: @escaping () -> [String: Any] = { [:] }) -> RelayConnection {
        var events = RelayConnection.Events()
        events.onState = { [self] in states.append($0) }
        events.onControl = { [self] in controls.append($0) }
        events.onEnvelope = { [self] in envelopes.append($0) }
        return RelayConnection(base: URL(string: "wss://relay.example.test")!, role: role, signer: identity,
                               extraAuthFields: extra, events: events, transports: factory,
                               schedule: { [self] d, body in scheduler.schedule(d, body) })
    }

    /// The relay's first frame; the connection must answer `auth`.
    private func challenge(_ t: FakeWebSocketTransport) {
        t.push(["type": "challenge", "nonce": Data(repeating: 7, count: 32).base64EncodedString()])
    }

    /// I4: a Secure Enclave key fails to sign for ordinary reasons (locked
    /// device, cancelled biometric prompt, timeout) — this stands in for
    /// that, unconditionally.
    private struct ThrowingSigner: RemoteSigner {
        struct SigningError: Error {}
        let id = "throws"
        let publicKeySPKI = Data([1, 2, 3])
        func sign(_ data: Data) throws -> Data { throw SigningError() }
    }

    func testConnectsToRolePathAndAnswersChallenge() {
        let c = make(role: .host, extra: { ["allowed": ["abc"]] })
        c.start()
        let t = factory.current
        XCTAssertEqual(t.url.path, "/host")
        XCTAssertTrue(t.resumed)
        XCTAssertEqual(states, [.connecting])
        challenge(t)
        let auth = t.lastSent!
        XCTAssertEqual(auth["type"] as? String, "auth")
        XCTAssertEqual(auth["publicKey"] as? String, identity.publicKeySPKI.base64EncodedString())
        let sig = Data(base64Encoded: auth["signature"] as! String)!
        XCTAssertEqual(sig.count, 64, "raw r‖s P-256 signature")
        XCTAssertEqual(auth["allowed"] as? [String], ["abc"], "host auth carries its allow-list")
        XCTAssertEqual(controls.last?["type"] as? String, "challenge",
                       "the connection answers the challenge itself but still reports it, so a host can log the handshake it just took part in")
    }

    func testAuthCarriesExtraFieldsPerRole() {
        let c = make(role: .client)
        c.start(); challenge(factory.current)
        XCTAssertNil(factory.current.lastSent!["allowed"], "a client sends no allow-list")
    }

    func testAuthedSetsConnectedAndForwardsControl() {
        let c = make()
        c.start(); challenge(factory.current)
        factory.current.push(["type": "authed", "id": identity.id])
        XCTAssertEqual(states.last, .connected)
        XCTAssertEqual(controls.last?["type"] as? String, "authed")
    }

    func testEnvelopesAreDecodedAndForwarded() {
        let c = make()
        c.start(); challenge(factory.current)
        factory.current.push(["type": "authed"])
        factory.current.push(["type": "env", "to": identity.id, "from": "abcdefghijklmnop", "payload": Data([1, 2, 3]).base64EncodedString()])
        XCTAssertEqual(envelopes.count, 1)
        XCTAssertEqual(envelopes.first?.from, "abcdefghijklmnop")
        XCTAssertEqual(envelopes.first?.payload, Data([1, 2, 3]))
        XCTAssertEqual(controls.filter { ($0["type"] as? String) == "env" }.count, 0, "envelopes never reach onControl")
    }

    func testFailureGoesOfflineAndReconnectsWithDoublingBackoff() {
        let c = make()
        c.start()
        factory.current.fail("boom")
        XCTAssertEqual(states.last, .offline("boom"))
        XCTAssertEqual(scheduler.pendingDelays.last, 1)
        scheduler.fireNext()                              // reconnect #1
        XCTAssertEqual(factory.made.count, 2)
        factory.current.fail("boom")
        XCTAssertEqual(scheduler.pendingDelays.last, 2)
        scheduler.fireNext()
        factory.current.fail("boom")
        XCTAssertEqual(scheduler.pendingDelays.last, 4)
        for _ in 0..<6 { scheduler.fireNext(); factory.current.fail("boom") }
        XCTAssertEqual(scheduler.pendingDelays.last, 30, "capped at 30 s")
    }

    func testBackoffResetsOnlyOnAuthed() {
        let c = make()
        // Each failure SCHEDULES the current backoff, then doubles it: the
        // delays a caller observes are 1, 2, 4, … and the point of this test
        // is that a socket which opens, and even challenges, but never
        // authenticates does not send that sequence back to 1.
        c.start(); factory.current.fail("x"); scheduler.fireNext()   // scheduled 1, next is 2
        factory.current.fail("x"); scheduler.fireNext()              // scheduled 2, next is 4
        challenge(factory.current)
        factory.current.fail("x")
        XCTAssertEqual(scheduler.pendingDelays.last, 4, "a challenge without authed must not reset the backoff")
        scheduler.fireNext()
        challenge(factory.current)
        factory.current.push(["type": "authed"])
        factory.current.fail("x")
        XCTAssertEqual(scheduler.pendingDelays.last, 1, "authed resets it")
    }

    func testStaleSocketFramesAreDropped() {
        let c = make()
        c.start()
        let first = factory.current
        c.stop()
        first.push(["type": "authed"])                                   // arrives after stop
        XCTAssertFalse(states.contains(.connected))
        c.start()
        let second = factory.current
        first.push(["type": "env", "to": identity.id, "from": "abcdefghijklmnop", "payload": "AQID"])
        XCTAssertTrue(envelopes.isEmpty, "a frame from the replaced socket is ignored")
        challenge(second); second.push(["type": "authed"])
        XCTAssertEqual(states.last, .connected)
    }

    /// I3: `start()` is a public entry point a caller (an iOS view model's
    /// `onAppear`, most plausibly) can call more than once. A second call
    /// must not orphan a live, already-authenticated socket.
    func testStartIsIdempotentAndClosesThePreviousSocket() {
        let c = make()
        c.start()
        challenge(factory.current)
        factory.current.push(["type": "authed"])
        let first = factory.current
        XCTAssertFalse(first.cancelled)
        c.start()
        XCTAssertTrue(first.cancelled, "the replaced socket is closed, not merely orphaned")
        XCTAssertEqual(factory.made.count, 2, "a second transport is made")
    }

    /// I4: a signing failure (the ordinary case for a Secure Enclave key —
    /// locked device, cancelled prompt, timeout) must not become an empty
    /// signature on the wire. It routes to the same path a dead socket
    /// takes: offline, with the normal reconnect backoff, since a locked
    /// phone may be unlocked by the time it fires.
    func testSigningFailureGoesOfflineWithoutSendingAuth() {
        var events = RelayConnection.Events()
        events.onState = { [self] in states.append($0) }
        let c = RelayConnection(base: URL(string: "wss://relay.example.test")!, role: .client,
                                signer: ThrowingSigner(), events: events, transports: factory,
                                schedule: { [self] d, body in scheduler.schedule(d, body) })
        c.start()
        challenge(factory.current)
        guard case .offline = states.last else {
            return XCTFail("expected .offline after a signing failure, got \(String(describing: states.last))")
        }
        XCTAssertNil(factory.current.lastSent, "no auth frame is ever sent when signing throws")
        XCTAssertEqual(scheduler.pendingDelays, [1], "a reconnect is scheduled with the normal backoff")
    }

    /// Recommendation 4: the ping's re-arm across a reconnect had no
    /// coverage — every other ping test stays within one generation.
    func testPingReArmsAndTargetsTheNewTransportAfterReconnect() {
        let c = make()
        c.start()
        factory.current.fail("boom")
        scheduler.fireNext()                                    // reconnect -> new transport
        XCTAssertEqual(scheduler.pendingDelays, [30], "ping re-armed after reconnect")
        let reconnected = factory.current
        scheduler.fireNext()                                    // fires the ping
        XCTAssertEqual(reconnected.pings, 1, "pings the NEW transport, not the replaced one")
    }

    func testStopCancelsTheLiveSocket() {
        let c = make()
        c.start()
        XCTAssertFalse(factory.current.cancelled)
        c.stop()
        XCTAssertTrue(factory.current.cancelled, "stop() cancels the socket it is holding")
        XCTAssertEqual(states.last, .off)
    }

    func testStopCancelsPendingWorkAndResetsBackoff() {
        let c = make()
        c.start(); factory.current.fail("x")            // schedules 1, next would be 2
        c.stop()
        XCTAssertTrue(scheduler.pendingDelays.isEmpty, "reconnect and ping work cancelled")
        c.start(); factory.current.fail("x")
        XCTAssertEqual(scheduler.pendingDelays.last, 1, "backoff reset by stop")
    }

    func testPingEveryThirtySecondsWhileConnected() {
        let c = make()
        c.start()
        XCTAssertEqual(scheduler.pendingDelays, [30])
        scheduler.fireNext()
        XCTAssertEqual(factory.current.pings, 1)
        XCTAssertEqual(scheduler.pendingDelays, [30], "re-armed")
        c.stop()
        XCTAssertTrue(scheduler.pendingDelays.isEmpty)
    }

    func testSendCompletionAlwaysFires() {
        let c = make()
        let env = RemoteEnvelope(to: "abcdefghijklmnop", from: identity.id, payload: Data([9]))
        var fired = 0
        c.send(envelope: env) { fired += 1 }                              // no socket yet
        let exp = expectation(description: "completion hops to main")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(fired, 1)
        c.start()
        c.send(envelope: env) { fired += 1 }
        let exp2 = expectation(description: "sent completion")
        DispatchQueue.main.async { exp2.fulfill() }
        wait(for: [exp2], timeout: 1)
        XCTAssertEqual(fired, 2)
        XCTAssertEqual(factory.current.lastSent?["type"] as? String, "env")
    }

    func testSendControlIsNoOpWithoutSocket() {
        let c = make()
        c.send(control: ["type": "allowed", "devices": []])
        XCTAssertTrue(factory.made.isEmpty)
    }

    /// A base URL that cannot produce a `/host`-or-`/client` URL is a
    /// configuration error, not a transient one: `connect()` must not leave
    /// `running == true` with a reconnect that can never succeed (a live
    /// bug fixed alongside this test — the old code called
    /// `setState(.offline(...))` here and scheduled nothing, a dead end).
    /// `RelayConnection.connectURL` is exercised directly first to confirm
    /// no `URL` this suite could construct actually trips it — Foundation's
    /// `URLComponents` turned out to accept every malformed base tried,
    /// including `wss://` itself — so the failure is simulated through the
    /// injectable `makeConnectURL`, the same seam `transports` and
    /// `schedule` already use for deterministic tests.
    func testUnusableConnectURLGoesOffAndSchedulesNothing() {
        XCTAssertNotNil(RelayConnection.connectURL(URL(string: "wss://")!, .host),
                        "documents that this base does NOT trip the real builder")
        var events = RelayConnection.Events()
        events.onState = { [self] in states.append($0) }
        let c = RelayConnection(base: URL(string: "wss://relay.example.test")!, role: .host, signer: identity,
                                events: events, transports: factory,
                                schedule: { [self] d, body in scheduler.schedule(d, body) },
                                makeConnectURL: { _, _ in nil })
        c.start()
        XCTAssertEqual(c.state, .off, "off, not offline — a bad config, not a dropped connection")
        XCTAssertTrue(states.isEmpty, "off → off is not a transition; nothing new to tell a caller")
        XCTAssertTrue(factory.made.isEmpty, "no transport is made")
        XCTAssertTrue(scheduler.pendingDelays.isEmpty, "no reconnect or ping is scheduled")
    }
}
