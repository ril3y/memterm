# MemtermRemoteKit Extraction + Shared RelayConnection — Implementation Plan (plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the remote-attach protocol, crypto, and relay-client code into a new SwiftPM target `MemtermRemoteKit` that builds for macOS 14 and iOS 17, and make the Mac host use the shared `RelayConnection` — with no behavior change visible to a user, a relay, or the probe suite.

**Architecture:** `MemtermRemoteKit` is a Foundation+CryptoKit-only target. `MemtermCore` and the `memterm` app depend on it. `RelayConnection` (new, in the kit) owns one relay socket: challenge/auth, envelope framing, ping, receive loop with a generation guard, and reconnect with backoff 1 s → 30 s. It is transport-agnostic (`WebSocketTransport` protocol) so it is unit-tested with a fake; the production transport wraps `URLSessionWebSocketTask`. `RemoteHost` (Mac) keeps everything host-specific (sessions, pairing, devices, dispatch) and delegates the socket to `RelayConnection`. `RemoteProbeClient` uses the same connection in the client role, which deletes its duplicate auth code.

**Tech Stack:** Swift 5.10, SwiftPM, CryptoKit, URLSessionWebSocketTask, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-28-ios-remote-app-design.md` (sections 3, 3.1, 5, 6-1). The remote-attach protocol itself is `docs/superpowers/specs/2026-09-19-remote-attach-design.md` and is unchanged.

## Global Constraints

- Everything under `Sources/MemtermRemoteKit/` imports only `Foundation` and `CryptoKit`. No AppKit, UIKit, Security, libproc, SQLite, or `CProcShim`.
- Package platforms become `[.macOS(.v14), .iOS(.v17)]`. Only the kit must actually compile for iOS; nothing else changes platform.
- No behavior change: the relay wire protocol, message ordering, reconnect timings (1 s doubling to a 30 s cap, reset to 1 s on `authed`), the 30 s ping, and every probe sentinel stay identical. `scripts/verify.sh`'s existing checks are the regression net; none is edited.
- `Tests/vectors/remote-crypto-vectors.json` does not move; the web tests read it by a fixed relative path.
- Callbacks from `RelayConnection` are delivered on the main queue, in receive order.
- Commit after every task with the session's attribution trailer.
- Run every command from the worktree root with literal paths; never `cd`, never variable-prefixed commands (a guard rejects both). Never bare `git stash`.

## Review Focus

Five conditions the spec implies and a person would expect to hold; each has its test in the task that owns the code:

1. A frame that arrives on a socket after `stop()` or after a reconnect must be ignored (generation guard), never delivered as if from the live socket — Task 2, `testStaleSocketFramesAreDropped`.
2. Backoff resets to 1 s only when the relay answers `authed`, not merely on socket open, so a relay that accepts TCP but never authenticates does not get hammered — Task 2, `testBackoffResetsOnlyOnAuthed`.
3. `send(envelope:completion:)` always calls its completion exactly once, including when there is no socket, so the host's backpressure accounting can never wait forever — Task 2, `testSendCompletionAlwaysFires`.
4. The host's `auth` frame carries its allow-list (`allowed`) exactly as today; a client's does not — Task 2, `testAuthCarriesExtraFieldsPerRole`, and Task 3's probe run (the relay rejects a host without it only implicitly, so the field is pinned by test).
5. Moving the tests must not silently drop any: the count of `Remote*`/`OutputBacklog`/`UnlockRateLimiter` tests after the move equals the count before — Task 1, Step 6.

---

## File Structure

```
Package.swift                                   platforms + new targets, dependency edges
Sources/MemtermRemoteKit/
  Protocol/RemoteMessage.swift                  (moved)
  Protocol/RemoteEnvelope.swift                 (moved)
  Protocol/RemoteTree.swift                     (moved)
  Crypto/RemoteCrypto.swift                     (moved; RemoteIdentity, RemoteHandshake, RemoteSessionKeys, RemotePairing)
  Crypto/RemoteDeviceSeal.swift                 (moved)
  Support/OutputBacklog.swift                   (moved)
  Support/UnlockRateLimiter.swift               (moved)
  Support/RemotePairingPage.swift               (moved)
  Relay/RemoteSigner.swift                      NEW protocol: id, publicKeySPKI, sign(_:)
  Relay/WebSocketTransport.swift                NEW protocol + URLSessionWebSocketTransport
  Relay/RelayConnection.swift                   NEW: the shared relay client
Tests/MemtermRemoteKitTests/                    (moved tests + new RelayConnectionTests.swift, FakeWebSocketTransport.swift)
Sources/MemtermCore/Config.swift                + import MemtermRemoteKit
Sources/memterm/Remote/RemoteHost.swift         uses RelayConnection; loses its socket code
Sources/memterm/Remote/RemoteProbeClient.swift  uses RelayConnection (client role)
Sources/memterm/Remote/*.swift, ProbeLegs.swift + import MemtermRemoteKit
```

---

### Task 1: Create the kit target and move the pure code and its tests

**Files:**
- Modify: `Package.swift`
- Move (git mv): the eight files under `Sources/MemtermCore/Remote/` to `Sources/MemtermRemoteKit/{Protocol,Crypto,Support}/` as listed in File Structure
- Move (git mv): `Tests/MemtermCoreTests/{RemoteMessageTests,RemoteTreeTests,RemoteCryptoTests,RemotePairingPageTests,OutputBacklogTests,UnlockRateLimiterTests}.swift` → `Tests/MemtermRemoteKitTests/`
- Modify: `Sources/MemtermCore/Config.swift` (add `import MemtermRemoteKit`)
- Modify: `Sources/memterm/ProbeLegs.swift`, `Sources/memterm/Remote/RemoteDeviceStore.swift`, `RemoteHost.swift`, `RemoteHost+Dispatch.swift`, `RemoteProbeClient.swift`, `RemotePaneStream.swift`, `RemoteSettingsSection.swift` (add `import MemtermRemoteKit`)

**Interfaces:**
- Produces: module `MemtermRemoteKit` exporting every currently-`public` type from the moved files unchanged. Later tasks import it.

- [ ] **Step 1: Record the test count before the move**

Run: `swift test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -n 1`
Expected: a line like `Executed 489 tests, with 0 failures`. Write the number down; Step 6 compares against it.

- [ ] **Step 2: Add the targets and platforms to Package.swift**

Replace the `platforms:` block and add the kit and its tests; make `MemtermCore`, `memterm`, and `MemtermCoreTests` depend on the kit:

```swift
    platforms: [
        .macOS(.v14),
        // The iPhone client (spec 2026-09-28) imports MemtermRemoteKit only;
        // nothing else in this package is built for iOS.
        .iOS(.v17)
    ],
```

```swift
        // Remote attach, shared with the iPhone client: protocol, crypto,
        // relay client. Foundation + CryptoKit only — no AppKit/UIKit,
        // Security, libproc, SQLite. Both apps and MemtermCore depend on it.
        .target(
            name: "MemtermRemoteKit",
            path: "Sources/MemtermRemoteKit"
        ),
```

Change the `MemtermCore` target to `dependencies: ["CProcShim", "MemtermRemoteKit"]`, add `"MemtermRemoteKit"` to the `memterm` executable's dependency list (after `"MemtermCore"`), add `"MemtermRemoteKit"` to `MemtermCoreTests` dependencies, and add:

```swift
        // Kit tests: the moved Remote* suites plus the relay connection
        // against a fake transport. Headless, no app, no relay process.
        .testTarget(
            name: "MemtermRemoteKitTests",
            dependencies: ["MemtermRemoteKit"],
            path: "Tests/MemtermRemoteKitTests"
        ),
```

- [ ] **Step 3: Move the sources**

```bash
mkdir -p Sources/MemtermRemoteKit/Protocol Sources/MemtermRemoteKit/Crypto Sources/MemtermRemoteKit/Support Sources/MemtermRemoteKit/Relay Tests/MemtermRemoteKitTests
git mv Sources/MemtermCore/Remote/RemoteMessage.swift Sources/MemtermRemoteKit/Protocol/RemoteMessage.swift
git mv Sources/MemtermCore/Remote/RemoteEnvelope.swift Sources/MemtermRemoteKit/Protocol/RemoteEnvelope.swift
git mv Sources/MemtermCore/Remote/RemoteTree.swift Sources/MemtermRemoteKit/Protocol/RemoteTree.swift
git mv Sources/MemtermCore/Remote/RemoteCrypto.swift Sources/MemtermRemoteKit/Crypto/RemoteCrypto.swift
git mv Sources/MemtermCore/Remote/RemoteDeviceSeal.swift Sources/MemtermRemoteKit/Crypto/RemoteDeviceSeal.swift
git mv Sources/MemtermCore/Remote/OutputBacklog.swift Sources/MemtermRemoteKit/Support/OutputBacklog.swift
git mv Sources/MemtermCore/Remote/UnlockRateLimiter.swift Sources/MemtermRemoteKit/Support/UnlockRateLimiter.swift
git mv Sources/MemtermCore/Remote/RemotePairingPage.swift Sources/MemtermRemoteKit/Support/RemotePairingPage.swift
git mv Tests/MemtermCoreTests/RemoteMessageTests.swift Tests/MemtermRemoteKitTests/RemoteMessageTests.swift
git mv Tests/MemtermCoreTests/RemoteTreeTests.swift Tests/MemtermRemoteKitTests/RemoteTreeTests.swift
git mv Tests/MemtermCoreTests/RemoteCryptoTests.swift Tests/MemtermRemoteKitTests/RemoteCryptoTests.swift
git mv Tests/MemtermCoreTests/RemotePairingPageTests.swift Tests/MemtermRemoteKitTests/RemotePairingPageTests.swift
git mv Tests/MemtermCoreTests/OutputBacklogTests.swift Tests/MemtermRemoteKitTests/OutputBacklogTests.swift
git mv Tests/MemtermCoreTests/UnlockRateLimiterTests.swift Tests/MemtermRemoteKitTests/UnlockRateLimiterTests.swift
rmdir Sources/MemtermCore/Remote
```

The vectors path in `RemoteCryptoTests.swift` (`#filePath` → two `deletingLastPathComponent()` → `vectors/remote-crypto-vectors.json`) resolves to `Tests/vectors/...` from the new directory exactly as before: same depth. Do not edit it.

- [ ] **Step 4: Fix the imports**

In each moved test file, change `@testable import MemtermCore` to `@testable import MemtermRemoteKit`. If a moved test also uses a `MemtermCore` type (grep first: `grep -l 'Config\b\|StateStore\|MemoryEngine' Tests/MemtermRemoteKitTests/*.swift`), that test stays in `MemtermCoreTests` instead — move it back and add `import MemtermRemoteKit` there. Add `import MemtermRemoteKit` under `import Foundation` in `Sources/MemtermCore/Config.swift` and in each of the seven app files listed above. `ConfigTests.swift` keeps `@testable import MemtermCore` and gains `import MemtermRemoteKit` only if it names a kit type directly (it references `Config.remoteWebURL`, which is Core; check with the compiler).

- [ ] **Step 5: Build and fix visibility**

Run: `swift build 2>&1 | grep -E 'error:' | head -20`
Expected: zero errors. If an error names a kit symbol as inaccessible (e.g. `'HelloWire' is inaccessible due to 'internal' protection level` or a `static let` used by the app), make that declaration `public` in the kit — that is the only permitted change to moved files. Record each one in the commit message.

- [ ] **Step 6: Run the suites and compare counts**

Run: `swift test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -n 1`
Expected: the SAME total as Step 1, 0 failures. (The kit tests now run under a second bundle; the grand total printed last must match.)
Run: `scripts/check-extension-firewall.sh | tail -n 2`
Expected: `FIREWALL-PASS`.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/MemtermRemoteKit Sources/MemtermCore Sources/memterm Tests
git commit -m "kit: extract remote protocol, crypto and support into MemtermRemoteKit (macOS 14 / iOS 17)

Pure move of Sources/MemtermCore/Remote/* and their tests; MemtermCore
and the app depend on the kit. Visibility widened for: <list or 'none'>.
Test count unchanged: <N>.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012saq7F94hZ4MqMnZLvBXzM"
```

---

### Task 2: `RelayConnection` in the kit, unit-tested against a fake transport

**Files:**
- Create: `Sources/MemtermRemoteKit/Relay/RemoteSigner.swift`
- Create: `Sources/MemtermRemoteKit/Relay/WebSocketTransport.swift`
- Create: `Sources/MemtermRemoteKit/Relay/RelayConnection.swift`
- Create: `Tests/MemtermRemoteKitTests/FakeWebSocketTransport.swift`
- Create: `Tests/MemtermRemoteKitTests/RelayConnectionTests.swift`

**Interfaces:**
- Consumes: `RemoteIdentity` (`id`, `publicKeySPKI`, `sign(_:)`) and `RemoteEnvelope` (`init(to:from:payload:)`, `encode()`, `decode(_:)`) from Task 1.
- Produces:

```swift
public protocol RemoteSigner {
    var id: String { get }
    var publicKeySPKI: Data { get }
    func sign(_ data: Data) -> Data
}
extension RemoteIdentity: RemoteSigner {}

public protocol WebSocketTransport: AnyObject {
    func resume()
    func send(_ text: String, completion: @escaping (Error?) -> Void)
    func sendPing(_ completion: @escaping (Error?) -> Void)
    func receive(_ handler: @escaping (Result<String, Error>) -> Void)   // one frame per call, re-armed by the caller
    func cancel()
}
public protocol WebSocketTransportFactory { func makeTransport(url: URL) -> WebSocketTransport }
public final class URLSessionWebSocketTransport: WebSocketTransport { public init(url: URL) }
public struct URLSessionTransportFactory: WebSocketTransportFactory { public init() }

public final class RelayConnection {
    public enum Role: String { case host, client }
    public enum State: Equatable { case off, connecting, connected, offline(String?) }
    public struct Events {
        public var onState: (State) -> Void = { _ in }
        public var onControl: ([String: Any]) -> Void = { _ in }   // every non-"env" JSON object, "authed" included
        public var onEnvelope: (RemoteEnvelope) -> Void = { _ in }
        public init() {}
    }
    public init(base: URL, role: Role, signer: RemoteSigner, extraAuthFields: @escaping () -> [String: Any] = { [:] },
                events: Events, transports: WebSocketTransportFactory = URLSessionTransportFactory(),
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = RelayConnection.mainQueueSchedule)
    public private(set) var state: State
    public func start()
    public func stop()
    public func send(control: [String: Any])
    public func send(envelope: RemoteEnvelope, completion: (() -> Void)?)
    public static let pingInterval: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 30
}
```

Semantics (all on the main queue):
- `start()`: state `connecting`; URL = base with path `/host` or `/client`; `transport.resume()`; arm receive; arm ping every 30 s.
- On `{"type":"challenge","nonce":<b64>}`: send `{"type":"auth","publicKey":<b64 SPKI>,"signature":<b64 sign(nonce)>} + extraAuthFields()`.
- On `{"type":"authed", ...}`: backoff ← 1 s, state `connected`, then `onControl` with the object (so `RemoteHost` can send its allow-list and pending pair token exactly as it does now).
- Any other non-`env` object → `onControl`. `{"type":"env",...}` → `RemoteEnvelope.decode` → `onEnvelope` (undecodable envelopes are dropped).
- Receive failure: state `offline(error.localizedDescription)`; if not stopped, schedule reconnect after `backoff`, then `backoff = min(backoff * 2, 30)`.
- `stop()`: generation += 1 (drops any in-flight callbacks), cancel ping and reconnect work, `transport.cancel()`, backoff ← 1, state `off`.
- `send(control:)`: JSON-serialize and send on the current transport; no-op without one.
- `send(envelope:completion:)`: `envelope.encode()` → text → transport send; the completion is invoked exactly once on the main queue whether or not a transport exists or the send fails.
- `schedule` is injectable so tests control time; `mainQueueSchedule` wraps `DispatchQueue.main.asyncAfter`.

- [ ] **Step 1: Write the fake transport**

`Tests/MemtermRemoteKitTests/FakeWebSocketTransport.swift`:

```swift
import Foundation
@testable import MemtermRemoteKit

/// A transport the test drives by hand: it records outbound frames and lets
/// the test push inbound frames or a failure into the pending receive.
final class FakeWebSocketTransport: WebSocketTransport {
    let url: URL
    private(set) var sent: [String] = []
    private(set) var pings = 0
    private(set) var cancelled = false
    private(set) var resumed = false
    private var pending: ((Result<String, Error>) -> Void)?

    init(url: URL) { self.url = url }
    func resume() { resumed = true }
    func send(_ text: String, completion: @escaping (Error?) -> Void) { sent.append(text); completion(nil) }
    func sendPing(_ completion: @escaping (Error?) -> Void) { pings += 1; completion(nil) }
    func receive(_ handler: @escaping (Result<String, Error>) -> Void) { pending = handler }
    func cancel() { cancelled = true }

    /// Delivers one inbound frame to whoever is waiting (synchronously).
    func push(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        let handler = pending; pending = nil
        handler?(.success(String(data: data, encoding: .utf8)!))
    }
    func fail(_ message: String) {
        let handler = pending; pending = nil
        handler?(.failure(NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: message])))
    }
    var lastSent: [String: Any]? {
        guard let last = sent.last, let data = last.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

final class FakeTransportFactory: WebSocketTransportFactory {
    private(set) var made: [FakeWebSocketTransport] = []
    func makeTransport(url: URL) -> WebSocketTransport {
        let t = FakeWebSocketTransport(url: url); made.append(t); return t
    }
    var current: FakeWebSocketTransport { made.last! }
}

/// A manual scheduler: work runs only when the test says `fire()`.
final class FakeScheduler {
    private(set) var queue: [(delay: TimeInterval, item: DispatchWorkItem)] = []
    func schedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: body); queue.append((delay, item)); return item
    }
    /// Runs and removes the earliest pending item that was not cancelled.
    func fireNext() {
        guard !queue.isEmpty else { return }
        let (_, item) = queue.removeFirst()
        if !item.isCancelled { item.perform() }
    }
    var pendingDelays: [TimeInterval] { queue.filter { !$0.item.isCancelled }.map(\.delay) }
}
```

- [ ] **Step 2: Write the failing tests**

`Tests/MemtermRemoteKitTests/RelayConnectionTests.swift`:

```swift
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
        identity = RemoteIdentity()   // fresh P-256 key
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
        c.start(); factory.current.fail("x"); scheduler.fireNext()      // backoff now 2
        factory.current.fail("x"); scheduler.fireNext()                 // backoff now 4
        // A socket that opens (and even challenges) but never authenticates keeps the backoff.
        challenge(factory.current)
        factory.current.fail("x")
        XCTAssertEqual(scheduler.pendingDelays.last, 8)
        scheduler.fireNext()
        challenge(factory.current)
        factory.current.push(["type": "authed"])                         // reset
        factory.current.fail("x")
        XCTAssertEqual(scheduler.pendingDelays.last, 1)
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

    func testStopCancelsEverythingAndResetsBackoff() {
        let c = make()
        c.start(); factory.current.fail("x")                             // schedules reconnect, backoff 2
        c.stop()
        XCTAssertEqual(states.last, .off)
        XCTAssertTrue(scheduler.pendingDelays.isEmpty, "reconnect and ping work cancelled")
        XCTAssertTrue(factory.current.cancelled)
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
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter RelayConnectionTests 2>&1 | grep -E 'error:|Executed' | head -5`
Expected: compile errors naming `RelayConnection`, `WebSocketTransport`, `FakeTransportFactory` — the types do not exist yet.

- [ ] **Step 4: Write the signer and transport**

`Sources/MemtermRemoteKit/Relay/RemoteSigner.swift`:

```swift
import Foundation

/// What the relay client needs from an identity: its peer id, its SPKI for
/// the `auth` frame, and a raw r‖s signature over the relay's nonce. The
/// Mac's Keychain-backed key and the phone's Secure Enclave key both fit.
public protocol RemoteSigner {
    var id: String { get }
    var publicKeySPKI: Data { get }
    func sign(_ data: Data) -> Data
}

extension RemoteIdentity: RemoteSigner {}
```

`Sources/MemtermRemoteKit/Relay/WebSocketTransport.swift`:

```swift
import Foundation

/// One WebSocket, as the relay client uses it. `receive` delivers ONE frame
/// and must be re-armed by the caller — exactly URLSessionWebSocketTask's
/// contract, which keeps the production wrapper trivial and the fake honest.
public protocol WebSocketTransport: AnyObject {
    func resume()
    func send(_ text: String, completion: @escaping (Error?) -> Void)
    func sendPing(_ completion: @escaping (Error?) -> Void)
    func receive(_ handler: @escaping (Result<String, Error>) -> Void)
    func cancel()
}

public protocol WebSocketTransportFactory {
    func makeTransport(url: URL) -> WebSocketTransport
}

public final class URLSessionWebSocketTransport: WebSocketTransport {
    private let task: URLSessionWebSocketTask
    public init(url: URL) { task = URLSession.shared.webSocketTask(with: url) }
    public func resume() { task.resume() }
    public func send(_ text: String, completion: @escaping (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }
    public func sendPing(_ completion: @escaping (Error?) -> Void) { task.sendPing(pongReceiveHandler: completion) }
    public func receive(_ handler: @escaping (Result<String, Error>) -> Void) {
        task.receive { result in
            switch result {
            case .failure(let error): handler(.failure(error))
            case .success(.string(let text)): handler(.success(text))
            case .success(.data(let data)): handler(.success(String(decoding: data, as: UTF8.self)))
            case .success: handler(.success(""))
            }
        }
    }
    public func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

public struct URLSessionTransportFactory: WebSocketTransportFactory {
    public init() {}
    public func makeTransport(url: URL) -> WebSocketTransport { URLSessionWebSocketTransport(url: url) }
}
```

- [ ] **Step 5: Write RelayConnection**

`Sources/MemtermRemoteKit/Relay/RelayConnection.swift`:

```swift
import Foundation

/// The relay client shared by the Mac host (`/host`) and the phone
/// (`/client`): challenge/auth, envelope framing, a 30 s ping, a receive
/// loop guarded by a generation counter, and reconnect with backoff
/// 1 s → 30 s. It knows nothing about sessions, pairing, or devices; those
/// live in the caller and are driven by `Events`.
///
/// Threading: `start`, `stop`, and both `send`s are main-queue only. Every
/// callback is delivered on the main queue, in receive order. Transport
/// completions may arrive on any queue and are hopped to main here.
public final class RelayConnection {
    public enum Role: String { case host, client }
    public enum State: Equatable { case off, connecting, connected, offline(String?) }

    public struct Events {
        public var onState: (State) -> Void = { _ in }
        /// Every relay control object (anything whose "type" is not "env"),
        /// `authed` included — after the connection has updated its own state.
        public var onControl: ([String: Any]) -> Void = { _ in }
        public var onEnvelope: (RemoteEnvelope) -> Void = { _ in }
        public init() {}
    }

    public static let pingInterval: TimeInterval = 30
    public static let maxBackoff: TimeInterval = 30

    public private(set) var state: State = .off

    private let base: URL
    private let role: Role
    private let signer: RemoteSigner
    private let extraAuthFields: () -> [String: Any]
    private let events: Events
    private let transports: WebSocketTransportFactory
    private let schedule: (TimeInterval, @escaping () -> Void) -> DispatchWorkItem

    private var transport: WebSocketTransport?
    private var generation = 0
    private var backoff: TimeInterval = 1
    private var reconnectWork: DispatchWorkItem?
    private var pingWork: DispatchWorkItem?
    private var running = false

    public init(base: URL, role: Role, signer: RemoteSigner,
                extraAuthFields: @escaping () -> [String: Any] = { [:] },
                events: Events,
                transports: WebSocketTransportFactory = URLSessionTransportFactory(),
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> DispatchWorkItem = RelayConnection.mainQueueSchedule) {
        self.base = base; self.role = role; self.signer = signer
        self.extraAuthFields = extraAuthFields; self.events = events
        self.transports = transports; self.schedule = schedule
    }

    public static func mainQueueSchedule(_ delay: TimeInterval, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    // MARK: - Lifecycle

    public func start() {
        running = true
        connect()
    }

    public func stop() {
        running = false
        generation += 1
        reconnectWork?.cancel(); reconnectWork = nil
        pingWork?.cancel(); pingWork = nil
        transport?.cancel(); transport = nil
        backoff = 1
        setState(.off)
    }

    private func connect() {
        guard running else { return }
        generation += 1
        let gen = generation
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)
        parts?.path = "/" + role.rawValue
        guard let url = parts?.url else { setState(.offline("relay URL is not usable")); return }
        setState(.connecting)
        let socket = transports.makeTransport(url: url)
        transport = socket
        socket.resume()
        receive(on: socket, generation: gen)
        schedulePing(generation: gen)
    }

    private func receive(on socket: WebSocketTransport, generation gen: Int) {
        socket.receive { [weak self] result in
            Self.onMain {
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let error):
                    self.handleFailure(error)
                case .success(let text):
                    self.handleFrame(Data(text.utf8))
                    self.receive(on: socket, generation: gen)
                }
            }
        }
    }

    private func handleFailure(_ error: Error) {
        transport = nil
        pingWork?.cancel(); pingWork = nil
        setState(.offline(error.localizedDescription))
        guard running else { return }
        let work = schedule(backoff) { [weak self] in self?.connect() }
        reconnectWork = work
        backoff = min(backoff * 2, Self.maxBackoff)
    }

    private func schedulePing(generation gen: Int) {
        pingWork?.cancel()
        pingWork = schedule(Self.pingInterval) { [weak self] in
            guard let self, gen == self.generation, let socket = self.transport else { return }
            socket.sendPing { _ in }
            self.schedulePing(generation: gen)
        }
    }

    // MARK: - Frames

    private func handleFrame(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "challenge":
            guard let nonceB64 = object["nonce"] as? String, let nonce = Data(base64Encoded: nonceB64) else { return }
            var auth: [String: Any] = [
                "type": "auth",
                "publicKey": signer.publicKeySPKI.base64EncodedString(),
                "signature": signer.sign(nonce).base64EncodedString(),
            ]
            for (key, value) in extraAuthFields() { auth[key] = value }
            send(control: auth)
        case "authed":
            backoff = 1
            setState(.connected)
            events.onControl(object)
        case "env":
            guard let envelope = RemoteEnvelope.decode(data) else { return }
            events.onEnvelope(envelope)
        default:
            events.onControl(object)
        }
    }

    // MARK: - Sending

    public func send(control object: [String: Any]) {
        guard let transport, let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        transport.send(text) { _ in }
    }

    /// The completion fires exactly once, on the main queue, whether the
    /// frame was sent, failed, or there was no socket to send it on — a
    /// caller counting in-flight bytes must never wait forever.
    public func send(envelope: RemoteEnvelope, completion: (() -> Void)?) {
        guard let transport, let text = String(data: envelope.encode(), encoding: .utf8) else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        transport.send(text) { _ in
            guard let completion else { return }
            Self.onMain(completion)
        }
    }

    // MARK: - Helpers

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        events.onState(new)
    }

    static func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
}
```

Note for the implementer: `RemoteEnvelope.decode` — check the moved `RemoteEnvelope.swift` for the exact decoder name (`decode(_:)` or `init?(data:)`) and use that; do not add a second decoder.

- [ ] **Step 6: Run the tests until green**

Run: `swift test --filter RelayConnectionTests 2>&1 | grep -E 'error:|Executed|failed' | head -20`
Expected: `Executed 11 tests, with 0 failures`. If `testSendCompletionAlwaysFires` is flaky because `Self.onMain` runs synchronously on the main thread inside the fake's synchronous send, the completion fires before the expectation is even created — that is fine; the assertion counts calls, not timing.

- [ ] **Step 7: Full suite, then commit**

Run: `swift test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -n 1`
Expected: previous total + 11, 0 failures.

```bash
git add Sources/MemtermRemoteKit/Relay Tests/MemtermRemoteKitTests/FakeWebSocketTransport.swift Tests/MemtermRemoteKitTests/RelayConnectionTests.swift
git commit -m "kit: RelayConnection — the shared relay client (auth, envelopes, ping, reconnect) over an injectable transport

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012saq7F94hZ4MqMnZLvBXzM"
```

---

### Task 3: The Mac host and the probe client adopt `RelayConnection`

**Files:**
- Modify: `Sources/memterm/Remote/RemoteHost.swift` (remove the socket/reconnect/ping code; drive a `RelayConnection`)
- Modify: `Sources/memterm/Remote/RemoteProbeClient.swift` (client role; delete its own challenge/auth code)
- Modify: `docs/superpowers/specs/2026-09-19-remote-attach-design.md` (file map: kit paths)

**Interfaces:**
- Consumes: `RelayConnection`, `RemoteSigner` from Task 2.
- Produces: unchanged host behavior. `probeState` strings stay `"off" | "connecting" | "connected" | "offline"` and `probeLastError` stays populated for the probe leg and Settings.

- [ ] **Step 1: Map today's host code onto the connection**

In `RemoteHost.swift` delete: `task`, `generation`, `reconnectDelay`, `reconnectWork`, `pingWork`, `connect()`, `receive(on:generation:)`, `handleSocketFailure`, `scheduleReconnect`, `schedulePing`, and the socket parts of `disconnect(state:)`; keep `sendAuth`'s `allowed` field by passing it as `extraAuthFields`. Add:

```swift
    private var connection: RelayConnection?

    private func makeConnection(base: URL) -> RelayConnection {
        var events = RelayConnection.Events()
        events.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .off: self.setState("off", error: nil)
            case .connecting: self.setState("connecting", error: self.probeLastError)
            case .connected: self.setState("connected", error: nil)
            case .offline(let message):
                // Every session's keys are bound to this connection's
                // handshake, so a dropped socket ends them all; the device
                // re-Hellos on reconnect.
                self.tearDownAllSessions()
                self.setState("offline", error: message)
            }
        }
        events.onControl = { [weak self] object in self?.handleControl(object) }
        events.onEnvelope = { [weak self] envelope in self?.handleEnvelope(envelope) }
        return RelayConnection(base: base, role: .host, signer: identity,
                               extraAuthFields: { [weak self] in ["allowed": self?.store.allowedIds ?? []] },
                               events: events)
    }
```

`applyConfig` (the connect path): `connection?.stop(); connection = makeConnection(base: base); connection?.start()`. The disconnect path: `connection?.stop(); connection = nil; tearDownAllSessions(); relayBase = nil; setState(state, error: nil)`.

`handleRelay(_ data:)` becomes `handleControl(_ object: [String: Any])` with the SAME cases minus `challenge` (the connection answers it) and minus the JSON parsing; the `authed` case keeps `sendAllowed()` and `sendPairTokenIfPossible()` (the connection has already set `connected`, so the `probeState == "connected"` guard in `sendPairTokenIfPossible` still passes). `sendJSON(_:)` becomes `connection?.send(control:)`. `sendEnvelope(to:payload:completion:)` becomes `connection?.send(envelope: RemoteEnvelope(to:from:payload:), completion:)` with the same "no connection → complete on main" fallback. Keep every `log(...)` line that exists today, including `"relay → \(type)"` (now in `handleControl`).

- [ ] **Step 2: The probe client**

In `RemoteProbeClient.swift`, replace its `URLSessionWebSocketTask`, `receive`, and `challenge`/`auth` handling with a `RelayConnection(base:role: .client, signer: identity, events:)`; its `pair`, Hello, and inner-message handling stay as they are, fed by `onControl` (`paired`, `pair-denied`, `refused`, `online`, `offline`) and `onEnvelope`.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | grep -E 'error:' | head -20`
Expected: none.

- [ ] **Step 4: Unit and probe gates**

Run: `swift test 2>&1 | grep -E 'Executed [0-9]+ tests' | tail -n 1`
Expected: same total as the end of Task 2, 0 failures.

Build the stamped app and run the fresh probe with the remote leg, exactly as `scripts/verify.sh`'s `probe` function does (fresh EMPTY config file created with `: >`, fresh `MEMTERM_STATE_DIR`, `MEMTERM_UI_PROBE=1 MEMTERM_PROBE_MODE=fresh MEMTERM_PROBE_REMOTE=1`), then smoke save/verify with `MEMTERM_SMOKE_GOLDEN=Tests/goldens/smoke-restore-geometry.txt`. Put the commands in a script file under the scratchpad and run `sh <file>` (the worktree guard rejects inline loops and variable-prefixed commands).

Expected in the probe log: `UIPROBE-REMOTE paired=true listed=true attached=true echo_roundtrip=true resized=true reconnected=true revoked=true close_prunes=true bad_proof_denied=true` and `UIPROBE-PASS steps=N/N`; smoke `SMOKE-PASS run=save`, `SMOKE-GEOMETRY golden=match`, `SMOKE-PASS run=verify`. The `reconnected=true` field is the live proof that the connection's backoff path still brings the host back after the relay is killed and restarted.

- [ ] **Step 5: Update the design doc's file map**

In `docs/superpowers/specs/2026-09-19-remote-attach-design.md`, in the file-structure section, change `Sources/MemtermCore/Remote/` to `Sources/MemtermRemoteKit/` (with the Protocol/Crypto/Support/Relay subfolders) and add one line: "`Relay/RelayConnection.swift` — the relay client shared by the Mac host and the iPhone app (spec 2026-09-28)."

- [ ] **Step 6: Commit**

```bash
git add Sources/memterm/Remote/RemoteHost.swift Sources/memterm/Remote/RemoteProbeClient.swift docs/superpowers/specs/2026-09-19-remote-attach-design.md
git commit -m "app: the host and the probe client ride the kit's RelayConnection

No behavior change: same auth frame (allowed list included), same
reconnect/backoff and ping, same probeState strings; the remote probe leg
and smoke are the proof.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_012saq7F94hZ4MqMnZLvBXzM"
```

---

## Self-review (done while writing)

- **Spec coverage (plan 1's share):** kit target with the eight files and their tests (T1); `RelayConnection` with the spec's public surface, `RemoteSigner`, main-queue delivery, backoff and ping (T2); Mac host and probe client on the shared client, host behavior unchanged and proven by the existing probe leg (T3); design-doc file map (T3). iOS-side items (Secure Enclave identity, screens, universal links, CI) are plans 2 and 3.
- **Placeholders:** none; every step has code or an exact command. The one "check the exact name" note (envelope decoder) tells the implementer where to look rather than inventing a signature.
- **Type consistency:** `RelayConnection.Events` field names match between T2's tests and T3's `makeConnection`; `State` cases match the `probeState` mapping; `send(envelope:completion:)` is the same signature in T2 and T3.
- **Review Focus:** all five lines have their named test in T1/T2 or their probe field in T3.
