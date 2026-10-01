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

    override func setUp() async throws {
        try await super.setUp()
        factory = FakeTransportFactory(); scheduler = FakeScheduler()
        hostIdentity = RemoteIdentity.generate(); phoneIdentity = RemoteIdentity.generate()
        output = []
        paired = PairedHost(id: hostIdentity.id, publicKeySPKI: hostIdentity.publicKeySPKI,
                            relay: URL(string: "wss://relay.example.test")!,
                            name: "Mac mini", pairedAt: Date())
        session = HostSession(host: paired, signer: phoneIdentity) { [self] url, events in
            RelayConnection(base: url, role: .client, signer: phoneIdentity, events: events,
                            transports: factory, schedule: { [self] d, b in scheduler.schedule(d, b) })
        }
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

    func testUnreadableRecordDropsTheSessionRatherThanStalling() throws {
        session.start(); authenticate()
        let keys = try completeHandshake()
        try send(.tree(tree(panes: ["p1"])), with: keys)
        // A record sealed under the wrong keys: the counter/tag check fails.
        // `RemoteSessionKeys`' own initializer is internal to the kit (keys
        // are only ever meant to come out of a handshake), so the "wrong
        // keys" stand-in is itself derived, from an unrelated shared secret.
        let wrong = RemoteHandshake.deriveKeys(sharedSecret: Data(repeating: 9, count: 32),
                                               hostId: "wrong-host", deviceId: "wrong-device", iAmHost: true)
        factory.current.push(["type": "env", "to": phoneIdentity.id, "from": hostIdentity.id,
                              "payload": try wrong.seal(RemoteMessage.treeChanged.encode()).base64EncodedString()])
        guard case .failed = session.phase else {
            return XCTFail("expected .failed, got \(session.phase)")
        }
    }
}
