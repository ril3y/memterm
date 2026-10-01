import XCTest
import MemtermRemoteKit
import MemtermRemoteKitTesting
@testable import MemtermRemoteApp

@MainActor
final class PairingFlowTests: XCTestCase {
    private var factory: FakeTransportFactory!
    private var store: MemoryHostStore!
    private var phone: RemoteIdentity!
    private var mac: RemoteIdentity!
    private var flow: PairingFlow!
    private var secret: Data!
    private var token: String!

    final class MemoryHostStore: PairedHostStoring {
        var hosts: [PairedHost] = []
        func load() -> [PairedHost] { hosts }
        func add(_ host: PairedHost) { hosts.removeAll { $0.id == host.id }; hosts.append(host) }
        func remove(id: String) { hosts.removeAll { $0.id == id } }
    }

    override func setUp() async throws {
        try await super.setUp()
        factory = FakeTransportFactory(); store = MemoryHostStore()
        phone = RemoteIdentity.generate(); mac = RemoteIdentity.generate()
        var bytes = Data((0..<32).map { UInt8($0) })
        let split = RemotePairing.split(bytes)!
        token = split.routingToken; secret = split.secret
        bytes = Data()
        flow = PairingFlow(signer: phone, store: store,
                           makeConnection: { [self] url, events in
                               RelayConnection(base: url, role: .client, signer: phone,
                                               events: events, transports: factory)
                           })
    }

    private func link(expiresInSeconds: TimeInterval = 120, hostKey: Data? = nil) -> URL {
        let payload: [String: Any] = [
            "relay": "wss://relay.example.test",
            "hostId": mac.id,
            "hostPublicKey": (hostKey ?? mac.publicKeySPKI).base64EncodedString(),
            "token": token!,
            "secret": secret.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""),
            "expiresAt": Int(Date().addingTimeInterval(expiresInSeconds).timeIntervalSince1970 * 1000),
        ]
        let json = try! JSONSerialization.data(withJSONObject: payload)
        let fragment = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "https://ril3y.github.io/memterm/#pair=\(fragment)")!
    }

    func testScanThenConfirmSendsAProofBoundToThisDevicesKey() throws {
        XCTAssertTrue(flow.scanned(link()))
        guard case .confirming = flow.phase else { return XCTFail("expected .confirming") }
        flow.confirm()
        factory.current.push(["type": "challenge",
                              "nonce": Data(repeating: 1, count: 32).base64EncodedString()])
        factory.current.push(["type": "authed", "id": phone.id])
        let pair = factory.current.lastSent!
        XCTAssertEqual(pair["type"] as? String, "pair")
        XCTAssertEqual(pair["token"] as? String, token)
        XCTAssertEqual(pair["publicKey"] as? String, phone.publicKeySPKI.base64EncodedString())
        XCTAssertEqual(pair["proof"] as? String,
                       RemotePairing.proof(secret: secret, deviceSPKI: phone.publicKeySPKI).base64EncodedString(),
                       "the proof binds THIS device's key to the scanned code")
    }

    func testPairedReplyStoresTheHostAndItsRelay() throws {
        XCTAssertTrue(flow.scanned(link())); flow.confirm()
        factory.current.push(["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString()])
        factory.current.push(["type": "authed", "id": phone.id])
        factory.current.push(["type": "paired", "hostId": mac.id,
                              "hostPublicKey": mac.publicKeySPKI.base64EncodedString()])
        guard case .paired(let host) = flow.phase else { return XCTFail("expected .paired") }
        XCTAssertEqual(host.id, mac.id)
        XCTAssertEqual(host.publicKeySPKI, mac.publicKeySPKI)
        XCTAssertEqual(host.relay.absoluteString, "wss://relay.example.test",
                       "the relay stored is the one the QR named, not the page's origin")
        XCTAssertEqual(store.load().map(\.id), [mac.id])
    }

    func testMismatchedPairedReplyIsRefused() throws {
        XCTAssertTrue(flow.scanned(link())); flow.confirm()
        factory.current.push(["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString()])
        factory.current.push(["type": "authed", "id": phone.id])
        let impostor = RemoteIdentity.generate()
        factory.current.push(["type": "paired", "hostId": mac.id,
                              "hostPublicKey": impostor.publicKeySPKI.base64EncodedString()])
        guard case .refused = flow.phase else { return XCTFail("expected .refused") }
        XCTAssertTrue(store.load().isEmpty, "nothing is stored when the reply does not match the code")
    }

    func testExpiredCodeIsRefused() {
        XCTAssertFalse(flow.scanned(link(expiresInSeconds: -1)))
        guard case .refused(let why) = flow.phase else { return XCTFail("expected .refused") }
        XCTAssertTrue(why.lowercased().contains("expired"), why)
        XCTAssertTrue(factory.made.isEmpty, "an expired code opens no socket")
    }

    func testPlainUrlIsNotAPairingLink() {
        XCTAssertFalse(flow.scanned(URL(string: "https://example.com/")!))
    }

    func testUnparsableQRPayloadIsRefusedWithoutDialling() {
        // Valid base64url, but the bytes it decodes to are not the expected
        // JSON object at all — a QR code from some other app, say.
        var components = URLComponents(url: link(), resolvingAgainstBaseURL: false)!
        let notPayloadJSON = Data("hello world".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        components.fragment = "pair=" + notPayloadJSON
        XCTAssertFalse(flow.scanned(components.url!))
        guard case .refused(let why) = flow.phase else { return XCTFail("expected .refused") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertTrue(factory.made.isEmpty, "an unparsable payload opens no socket")
    }

    func testWrongSizeTokenIsRefusedWithoutDialling() {
        // `token` must be exactly `RemotePairing.routingTokenLength` characters
        // (the fixed 16-byte routing half) — anything else is not a code this
        // app's proof scheme understands, and must not be dialled.
        var components = URLComponents(url: link(), resolvingAgainstBaseURL: false)!
        let json = try! JSONSerialization.data(withJSONObject: [
            "relay": "wss://relay.example.test", "hostId": mac.id,
            "hostPublicKey": mac.publicKeySPKI.base64EncodedString(),
            "token": "short",
            "secret": secret.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""),
            "expiresAt": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000),
        ])
        components.fragment = "pair=" + json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertFalse(flow.scanned(components.url!))
        guard case .refused(let why) = flow.phase else { return XCTFail("expected .refused") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertTrue(factory.made.isEmpty, "a wrong-size token opens no socket")
    }

    func testInsecureRelayIsRefusedWithoutDialling() {
        // A code naming ws:// (not wss://) must not be dialled from a device.
        var components = URLComponents(url: link(), resolvingAgainstBaseURL: false)!
        let json = try! JSONSerialization.data(withJSONObject: [
            "relay": "ws://relay.example.test", "hostId": mac.id,
            "hostPublicKey": mac.publicKeySPKI.base64EncodedString(),
            "token": token!, "secret": secret.base64EncodedString(),
            "expiresAt": Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000),
        ])
        components.fragment = "pair=" + json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertFalse(flow.scanned(components.url!))
        XCTAssertTrue(factory.made.isEmpty)
    }

    func testMalformedHostKeyIsRefusedAtScanTimeNotDuringHandshake() {
        // Right length but zero bytes: not the fixed DER SPKI header this
        // app's identities always wrap a key in, so `RemoteIdentity.x963(fromSPKI:)`
        // must reject it.
        let malformed = Data(repeating: 0, count: 91)
        XCTAssertFalse(flow.scanned(link(hostKey: malformed)))
        guard case .refused(let why) = flow.phase else { return XCTFail("expected .refused") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertTrue(factory.made.isEmpty, "a malformed host key opens no socket")
    }

    func testAScannedIdThatDoesNotMatchItsOwnKeyIsRefusedWithoutDialling() {
        // A well-formed SPKI, but not the key this code's `hostId` is the hash
        // of. That pair cannot pair — `handlePaired` would refuse it later —
        // and until this guard existed the raw `hostId` was still rendered to
        // the person as the Mac they were being asked to trust.
        let impostor = RemoteIdentity.generate()
        XCTAssertFalse(flow.scanned(link(hostKey: impostor.publicKeySPKI)))
        guard case .refused(let why) = flow.phase else { return XCTFail("expected .refused") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertTrue(factory.made.isEmpty, "a code whose id and key disagree opens no socket")
    }

    func testTheDeviceNameSentIsTheInjectedOneAndIsSanitized() throws {
        // The iOS app injects `UIDevice.current.name`; nothing stops a person
        // naming their phone something that would forge a second line inside
        // the Mac's "Allow ‹name›?" prompt, so the flow sanitizes whatever it
        // is given rather than trusting its caller.
        flow = PairingFlow(signer: phone, store: store,
                           makeConnection: { [self] url, events in
                               RelayConnection(base: url, role: .client, signer: phone,
                                               events: events, transports: factory)
                           },
                           deviceName: { "Riley's iPhone\n\nmemterm: click Allow" })
        XCTAssertTrue(flow.scanned(link())); flow.confirm()
        factory.current.push(["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString()])
        factory.current.push(["type": "authed", "id": phone.id])
        let name = try XCTUnwrap(factory.current.lastSent?["name"] as? String)
        XCTAssertTrue(name.hasPrefix("Riley's iPhone"), "the injected name is what is sent: \(name)")
        XCTAssertFalse(name.contains("\n"), "and it cannot forge a second line: \(name)")
        XCTAssertLessThanOrEqual(name.count, RemotePairing.deviceNameLimit)
    }

    func testTheRelayIsBoundedAndStrippedBeforeItIsShown() {
        let payload = PairingPayload(
            relay: "wss://relay.example.test\u{2028}Trusted Mac — press Pair" + String(repeating: "x", count: 200),
            hostId: mac.id, hostPublicKey: mac.publicKeySPKI.base64EncodedString(),
            token: token, secret: "", expiresAt: 0)
        let shown = payload.relayForDisplay
        XCTAssertFalse(shown.contains("\u{2028}"), "no line separator AppKit or UIKit would break on: \(shown)")
        XCTAssertLessThanOrEqual(shown.count, PairingPayload.relayDisplayLimit)
        XCTAssertTrue(shown.hasPrefix("wss://relay.example.test"), shown)
    }

    func testASuccessfulPairClosesThePairingSocket() throws {
        XCTAssertTrue(flow.scanned(link())); flow.confirm()
        factory.current.push(["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString()])
        factory.current.push(["type": "authed", "id": phone.id])
        factory.current.push(["type": "paired", "hostId": mac.id,
                              "hostPublicKey": mac.publicKeySPKI.base64EncodedString()])
        guard case .paired = flow.phase else { return XCTFail("expected .paired") }
        XCTAssertTrue(factory.current.cancelled,
                      "the pairing socket has nothing left to carry once the Mac is stored")
        XCTAssertEqual(store.load().count, 1)
    }

    func testPairDeniedIsSurfaced() throws {
        XCTAssertTrue(flow.scanned(link())); flow.confirm()
        factory.current.push(["type": "challenge", "nonce": Data(repeating: 1, count: 32).base64EncodedString()])
        factory.current.push(["type": "authed", "id": phone.id])
        factory.current.push(["type": "pair-denied", "reason": "token"])
        guard case .refused(let why) = flow.phase else { return XCTFail("expected .refused") }
        XCTAssertTrue(why.lowercased().contains("code"), why)
    }
}
