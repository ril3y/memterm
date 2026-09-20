import CryptoKit
import XCTest
@testable import MemtermCore

// Remote-attach crypto (decision doc 2026-09-19). Every byte format here is a
// wire contract with two other implementations: the Node relay
// (`relay/src/auth.ts`) recomputes the peer id from the same SPKI bytes, and
// the phone's browser does the handshake in WebCrypto. So these tests pin
// formats, not just behaviour — and the vectors leg writes the file the web
// client's own suite will later read.
final class RemoteCryptoTests: XCTestCase {

    // MARK: - Fixtures

    /// The relay's base32 (`relay/src/auth.ts`), reimplemented here on
    /// purpose: if the production encoder drifts, this independent copy
    /// catches it instead of agreeing with the bug.
    private func referenceBase32(_ bytes: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var bits = 0
        var value = 0
        var out = ""
        for byte in bytes {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }

    private static let spkiHeaderHex = "3059301306072a8648ce3d020106082a8648ce3d030107034200"

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func bytes(fromHex string: String) throws -> Data {
        var out = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = try XCTUnwrap(string.index(index, offsetBy: 2, limitedBy: string.endIndex))
            out.append(try XCTUnwrap(UInt8(string[index..<next], radix: 16)))
            index = next
        }
        return out
    }

    // MARK: - (a) Identity

    func testGeneratedIdentityRoundTripsThroughRawPrivateKey() throws {
        let original = RemoteIdentity.generate()
        let restored = try RemoteIdentity(privateKeyRaw: original.privateKey.rawRepresentation)
        XCTAssertEqual(restored.publicKeySPKI, original.publicKeySPKI)
        XCTAssertEqual(restored.id, original.id)
    }

    /// The SPKI is what the relay stores and what peers pin, so its exact
    /// shape — 26-byte DER header then the 65-byte uncompressed point — is
    /// the contract.
    func testPublicKeyIsDERSubjectPublicKeyInfo() {
        let identity = RemoteIdentity.generate()
        let spki = identity.publicKeySPKI
        XCTAssertEqual(spki.count, 91)
        XCTAssertEqual(hex(spki.prefix(26)), Self.spkiHeaderHex)
        XCTAssertEqual(Data(spki.suffix(65)), identity.privateKey.publicKey.x963Representation)
        XCTAssertEqual(spki.suffix(65).first, 0x04, "uncompressed point marker")
    }

    /// `relay/src/auth.ts` computes exactly this; a mismatch means the host
    /// registers under an id the phone can never address.
    func testIdIsFirst16CharsOfLowercaseBase32SHA256OfSPKI() {
        let identity = RemoteIdentity.generate()
        let digest = Data(SHA256.hash(data: identity.publicKeySPKI))
        XCTAssertEqual(identity.id, String(referenceBase32(digest).prefix(16)))
        XCTAssertEqual(identity.id.count, 16)
        let alphabet = Set("abcdefghijklmnopqrstuvwxyz234567")
        XCTAssertTrue(identity.id.allSatisfy { alphabet.contains($0) }, identity.id)
    }

    func testDistinctIdentitiesGetDistinctIds() {
        XCTAssertNotEqual(RemoteIdentity.generate().id, RemoteIdentity.generate().id)
    }

    /// The raw key comes back from the Keychain, which is not a trusted
    /// length — a short blob must throw, never trap.
    func testMalformedPrivateKeyRawThrows() {
        XCTAssertThrowsError(try RemoteIdentity(privateKeyRaw: Data([1, 2, 3])))
        XCTAssertThrowsError(try RemoteIdentity(privateKeyRaw: Data()))
    }

    // MARK: - (b) Signing

    /// WebCrypto's ECDSA verify only accepts raw r‖s. DER would silently fail
    /// on the phone, so the width is pinned here.
    func testSignatureIsRaw64ByteRS() throws {
        let identity = RemoteIdentity.generate()
        let message = Data("attach please".utf8)
        let signature = identity.sign(message)
        XCTAssertEqual(signature.count, 64)

        let publicKey = try P256.Signing.PublicKey(
            x963Representation: identity.privateKey.publicKey.x963Representation
        )
        let parsed = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertTrue(publicKey.isValidSignature(parsed, for: message))
    }

    func testSignatureFailsForTamperedMessage() throws {
        let identity = RemoteIdentity.generate()
        let signature = identity.sign(Data("attach please".utf8))
        let publicKey = try P256.Signing.PublicKey(
            x963Representation: identity.privateKey.publicKey.x963Representation
        )
        let parsed = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        XCTAssertFalse(publicKey.isValidSignature(parsed, for: Data("attach elsewhere".utf8)))
    }

    // MARK: - (c) Handshake

    func testTwoPartiesDeriveMatchingKeysAndTalkBothDirections() throws {
        let hostIdentity = RemoteIdentity.generate()
        let clientIdentity = RemoteIdentity.generate()
        let (hostHello, hostEphemeral) = RemoteHandshake.makeHello(identity: hostIdentity)
        let (clientHello, clientEphemeral) = RemoteHandshake.makeHello(identity: clientIdentity)

        XCTAssertEqual(hostHello.ephemeralRaw.count, 65)
        XCTAssertEqual(hostHello.signature.count, 64)
        XCTAssertTrue(RemoteHandshake.verifyHello(clientHello, peerSPKI: clientIdentity.publicKeySPKI))
        XCTAssertTrue(RemoteHandshake.verifyHello(hostHello, peerSPKI: hostIdentity.publicKeySPKI))

        let hostKeys = try RemoteHandshake.deriveKeys(
            myEphemeral: hostEphemeral,
            peerEphemeralRaw: clientHello.ephemeralRaw,
            hostId: hostIdentity.id,
            deviceId: clientIdentity.id,
            iAmHost: true
        )
        let clientKeys = try RemoteHandshake.deriveKeys(
            myEphemeral: clientEphemeral,
            peerEphemeralRaw: hostHello.ephemeralRaw,
            hostId: hostIdentity.id,
            deviceId: clientIdentity.id,
            iAmHost: false
        )

        let toPhone = Data("\u{1b}[2J$ ".utf8)
        XCTAssertEqual(try clientKeys.open(try hostKeys.seal(toPhone)), toPhone)
        let toHost = Data("ls -la\n".utf8)
        XCTAssertEqual(try hostKeys.open(try clientKeys.seal(toHost)), toHost)

        // Counters advance independently per direction across a stream.
        for index in 0..<8 {
            let chunk = Data("frame \(index)".utf8)
            XCTAssertEqual(try clientKeys.open(try hostKeys.seal(chunk)), chunk)
        }
        for index in 0..<3 {
            let chunk = Data("key \(index)".utf8)
            XCTAssertEqual(try hostKeys.open(try clientKeys.seal(chunk)), chunk)
        }
    }

    /// A Hello signed by somebody else must not authenticate the peer we
    /// think we are talking to — that is the whole point of signing it.
    func testVerifyHelloRejectsWrongIdentityAndTamperedPoint() {
        let identity = RemoteIdentity.generate()
        let impostor = RemoteIdentity.generate()
        let (hello, _) = RemoteHandshake.makeHello(identity: identity)
        XCTAssertFalse(RemoteHandshake.verifyHello(hello, peerSPKI: impostor.publicKeySPKI))

        var tampered = hello
        tampered.ephemeralRaw[64] ^= 0x01
        XCTAssertFalse(RemoteHandshake.verifyHello(tampered, peerSPKI: identity.publicKeySPKI))

        var shortSPKI = identity.publicKeySPKI
        shortSPKI.removeLast(10)
        XCTAssertFalse(RemoteHandshake.verifyHello(hello, peerSPKI: shortSPKI))
        XCTAssertFalse(RemoteHandshake.verifyHello(hello, peerSPKI: Data()))
    }

    func testDeriveKeysRejectsMalformedPeerPoint() {
        let identity = RemoteIdentity.generate()
        let (_, ephemeral) = RemoteHandshake.makeHello(identity: identity)
        XCTAssertThrowsError(try RemoteHandshake.deriveKeys(
            myEphemeral: ephemeral,
            peerEphemeralRaw: Data(repeating: 0x04, count: 65),
            hostId: "abcdefghijklmnop",
            deviceId: "qrstuvwxyz234567",
            iAmHost: true
        ))
    }

    /// Key material is direction-split, so the side that sealed a record must
    /// not be able to open it — the tag fails rather than quietly working.
    func testHostCannotOpenItsOwnRecord() throws {
        let keys = RemoteHandshake.deriveKeys(
            sharedSecret: Data((1...32).map(UInt8.init)),
            hostId: "abcdefghijklmnop",
            deviceId: "qrstuvwxyz234567",
            iAmHost: true
        )
        let record = try keys.seal(Data("hello".utf8))
        XCTAssertThrowsError(try keys.open(record)) { error in
            XCTAssertEqual(error as? RemoteCryptoError, .malformed)
        }
    }

    // MARK: - (d) Replay

    func testReplayedRecordThrowsAndDoesNotAdvanceTheCounter() throws {
        let secret = Data((1...32).map(UInt8.init))
        let hostKeys = RemoteHandshake.deriveKeys(sharedSecret: secret, hostId: "h", deviceId: "d", iAmHost: true)
        let clientKeys = RemoteHandshake.deriveKeys(sharedSecret: secret, hostId: "h", deviceId: "d", iAmHost: false)

        let record0 = try hostKeys.seal(Data("zero".utf8))
        let record1 = try hostKeys.seal(Data("one".utf8))
        XCTAssertEqual(try clientKeys.open(record0), Data("zero".utf8))

        XCTAssertThrowsError(try clientKeys.open(record0)) { error in
            XCTAssertEqual(error as? RemoteCryptoError, .replay)
        }
        // A record from the future is equally refused, and neither refusal
        // may burn the counter: record1 must still open afterwards.
        let record2 = try hostKeys.seal(Data("two".utf8))
        XCTAssertThrowsError(try clientKeys.open(record2)) { error in
            XCTAssertEqual(error as? RemoteCryptoError, .replay)
        }
        XCTAssertEqual(try clientKeys.open(record1), Data("one".utf8))
        XCTAssertEqual(try clientKeys.open(record2), Data("two".utf8))
    }

    func testMalformedRecordsThrowMalformed() throws {
        let secret = Data((1...32).map(UInt8.init))
        let hostKeys = RemoteHandshake.deriveKeys(sharedSecret: secret, hostId: "h", deviceId: "d", iAmHost: true)
        let clientKeys = RemoteHandshake.deriveKeys(sharedSecret: secret, hostId: "h", deviceId: "d", iAmHost: false)

        for truncated in [Data(), Data(repeating: 0, count: 11), Data(repeating: 0, count: 27)] {
            XCTAssertThrowsError(try clientKeys.open(truncated)) { error in
                XCTAssertEqual(error as? RemoteCryptoError, .malformed, "count \(truncated.count)")
            }
        }

        let record = try hostKeys.seal(Data("hello".utf8))
        var corrupted = record
        corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0xFF
        XCTAssertThrowsError(try clientKeys.open(corrupted)) { error in
            XCTAssertEqual(error as? RemoteCryptoError, .malformed)
        }
        // A failed tag must not burn counter 0: the genuine record still opens.
        XCTAssertEqual(try clientKeys.open(record), Data("hello".utf8))
    }

    /// Record layout is nonce ‖ ciphertext ‖ tag with a big-endian counter,
    /// which is what the browser's AES-GCM call expects to see.
    func testRecordLayoutIsBigEndianCounterNoncePlusCombinedBox() throws {
        let keys = RemoteHandshake.deriveKeys(
            sharedSecret: Data((1...32).map(UInt8.init)),
            hostId: "h",
            deviceId: "d",
            iAmHost: true
        )
        let plaintext = Data("hello".utf8)
        let first = try keys.seal(plaintext)
        XCTAssertEqual(first.count, 12 + plaintext.count + 16)
        XCTAssertEqual(hex(first.prefix(12)), "000000000000000000000000")
        XCTAssertEqual(hex(try keys.seal(plaintext).prefix(12)), "000000000000000000000001")
        XCTAssertEqual(hex(try keys.seal(plaintext).prefix(12)), "000000000000000000000002")
    }

    /// Records reach `open` as whatever slicing the transport left behind,
    /// so index arithmetic must not assume a zero start index.
    func testOpenAcceptsARecordThatIsADataSlice() throws {
        let secret = Data((1...32).map(UInt8.init))
        let hostKeys = RemoteHandshake.deriveKeys(sharedSecret: secret, hostId: "h", deviceId: "d", iAmHost: true)
        let clientKeys = RemoteHandshake.deriveKeys(sharedSecret: secret, hostId: "h", deviceId: "d", iAmHost: false)

        let padded = Data(repeating: 0xEE, count: 7) + (try hostKeys.seal(Data("sliced".utf8)))
        let slice = padded.dropFirst(7)
        XCTAssertNotEqual(slice.startIndex, 0, "the fixture must actually be offset")
        XCTAssertEqual(try clientKeys.open(slice), Data("sliced".utf8))
    }

    // MARK: - (e) Shared vectors

    /// The web client's suite reads this same file. Set
    /// `MEMTERM_WRITE_VECTORS=1` to re-author it; otherwise it is a contract
    /// this side must keep.
    func testMatchesSharedVectors() throws {
        let sharedSecret = Data((1...32).map(UInt8.init))
        let hostId = "abcdefghijklmnop"
        let deviceId = "qrstuvwxyz234567"

        let hostKeys = RemoteHandshake.deriveKeys(
            sharedSecret: sharedSecret, hostId: hostId, deviceId: deviceId, iAmHost: true
        )
        let clientKeys = RemoteHandshake.deriveKeys(
            sharedSecret: sharedSecret, hostId: hostId, deviceId: deviceId, iAmHost: false
        )

        let produced: [String: String] = [
            "sharedSecretHex": hex(sharedSecret),
            "hostId": hostId,
            "deviceId": deviceId,
            "hostToClientKeyHex": hex(hostKeys.sendKeyBytes),
            "clientToHostKeyHex": hex(clientKeys.sendKeyBytes),
            "record0Hex": hex(try hostKeys.seal(Data("hello".utf8))),
        ]

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("vectors/remote-crypto-vectors.json")

        if ProcessInfo.processInfo.environment["MEMTERM_WRITE_VECTORS"] == "1" {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var json = String(decoding: try encoder.encode(produced), as: UTF8.self)
            json.append("\n")
            try json.write(to: url, atomically: true, encoding: .utf8)
        }

        let expected = try JSONDecoder().decode([String: String].self, from: try Data(contentsOf: url))
        XCTAssertEqual(produced, expected)

        // The two directions must not share a key.
        XCTAssertNotEqual(produced["hostToClientKeyHex"], produced["clientToHostKeyHex"])
        XCTAssertEqual(produced["hostToClientKeyHex"]?.count, 64)
        // The client opens exactly what the vectors record.
        let record0 = try bytes(fromHex: try XCTUnwrap(expected["record0Hex"]))
        XCTAssertEqual(try clientKeys.open(record0), Data("hello".utf8))
    }
}
