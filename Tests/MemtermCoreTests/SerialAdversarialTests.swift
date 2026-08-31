import Darwin
import XCTest
@testable import MemtermCore

// Gate-stage adversarial checks (feature/serial): independent oracles that do
// NOT reuse the implementation's helpers to build expectations — the hex rows
// are hand-computed strings, the auto-baud garbage is the classic wrong-baud
// byte soup, and the pty scenarios drive the raw fds directly.
final class SerialAdversarialTests: XCTestCase {

    // MARK: Hex dump vs a hand-computed oracle

    /// 21 bytes chosen to exercise every gutter rule at once: NUL, printable
    /// edges (0x20 space / 0x7E tilde), DEL (0x7F — first non-printable above
    /// the range), 0xFF, digits across the mid-row gap, and a newline inside
    /// the partial second row. Expected rows written out by hand.
    func testDumpMatchesHandComputedRows() {
        let bytes: [UInt8] = [0x00, 0x41, 0x7E, 0x7F, 0x20, 0x1F, 0xFF, 0x30,
                              0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38,
                              0x39, 0x61, 0x62, 0x0A, 0x63]
        let row0 = "00000000  00 41 7e 7f 20 1f ff 30  31 32 33 34 35 36 37 38"
            + "  |.A~. ..012345678|"
        // Partial row: 5 hex bytes, then 11 padded columns (the 8-column
        // mid-gap falls inside the padding) — 34 spaces before the gutter.
        let row1 = "00000010  39 61 62 0a 63" + String(repeating: " ", count: 34)
            + "  |9ab.c|"
        XCTAssertEqual(SerialHex.dump(Data(bytes)), row0 + "\n" + row1 + "\n")

        // Byte-identical when streamed one byte at a time.
        var f = HexDumpFormatter()
        var streamed = ""
        for b in bytes { streamed += f.append([b]) }
        streamed += f.flush()
        XCTAssertEqual(streamed, row0 + "\n" + row1 + "\n")
    }

    /// Offsets are byte counts, not row counts: after a 16-byte row and a
    /// flush of 3 more, the next appended row starts at 0x13.
    func testOffsetsCountBytesAcrossFlush() {
        var f = HexDumpFormatter()
        _ = f.append([UInt8](repeating: 0x41, count: 16))   // row at 0x00
        _ = f.append([0x42, 0x42, 0x42])                    // partial…
        _ = f.flush()                                        // …emitted at 0x10
        _ = f.flush()
        let next = f.append([UInt8](repeating: 0x43, count: 16))
        XCTAssertTrue(next.hasPrefix("00000013  "), next)
    }

    // MARK: Auto-baud must not be confidently wrong

    /// The classic wrong-baud artifact soup (NUL/0xFF/high-bit framing trash)
    /// at EVERY rate: the scorer must stay near zero and the ranker must
    /// refuse to pick a winner.
    func testWrongBaudGarbageEverywhereIsNeverLikely() {
        let soup: [UInt8] = Array(repeating: [0x00, 0xFF, 0xFE, 0x80, 0x9C, 0xC0, 0x00, 0xF8],
                                  count: 8).flatMap { $0 }
        XCTAssertLessThan(SerialAutoBaud.score(soup), 0.1)
        let samples = SerialAutoBaud.candidateRates.map { (rate: $0, bytes: soup) }
        guard case .inconclusive(let ranking) = SerialAutoBaud.rank(samples: samples) else {
            return XCTFail("garbage at all rates must be inconclusive")
        }
        XCTAssertTrue(ranking.allSatisfy { $0.confidence < 0.1 })
    }

    /// Deterministic pseudo-random noise (seeded LCG): uniformly random bytes
    /// are ~37% printable, which must still land far below the accept
    /// threshold — noise never becomes a confident answer.
    func testUniformRandomNoiseStaysBelowThreshold() {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        var noise: [UInt8] = []
        for _ in 0..<512 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            noise.append(UInt8(truncatingIfNeeded: state >> 33))
        }
        XCTAssertLessThan(SerialAutoBaud.score(noise), SerialAutoBaud.acceptThreshold)
        let samples = SerialAutoBaud.candidateRates.map { (rate: $0, bytes: noise) }
        if case .likely(let rate, let confidence, _) = SerialAutoBaud.rank(samples: samples) {
            XCTFail("noise ranked .likely(\(rate)) at \(confidence)")
        }
    }

    // MARK: Typed errors, no crashes

    func testErrnoMappingCoversTheSheetPaths() {
        XCTAssertEqual(SerialError.fromErrno(EBUSY), .busy)
        XCTAssertEqual(SerialError.fromErrno(ENOENT), .vanished)
        XCTAssertEqual(SerialError.fromErrno(ENXIO), .vanished)
        XCTAssertEqual(SerialError.fromErrno(ENODEV), .vanished)
        XCTAssertEqual(SerialError.fromErrno(EACCES), .permissionDenied)
        XCTAssertEqual(SerialError.fromErrno(ENOTTY), .lineControlUnsupported)
        XCTAssertEqual(SerialError.fromErrno(EIO), .io(errno: EIO))
    }

    /// Double-open of one connection is a typed error, not a leaked fd or a
    /// crash; the original session keeps working afterwards.
    func testSecondOpenOnLiveConnectionThrowsTyped() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        defer { close(master) }
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let name = ptsname(master) else {
            throw SerialError.io(errno: errno)
        }
        let conn = SerialConnection(path: String(cString: name))
        defer { conn.close() }
        try conn.open(settings: SerialSettings())
        XCTAssertThrowsError(try conn.open(settings: SerialSettings())) {
            XCTAssertEqual($0 as? SerialError, .io(errno: EALREADY))
        }
        XCTAssertTrue(conn.isOpen)
        try conn.write(Data([0x21]))
        var buf = [UInt8](repeating: 0, count: 4)
        var pfd = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&pfd, 1, 2000), 0)
        XCTAssertEqual(read(master, &buf, buf.count), 1)
        XCTAssertEqual(buf[0], 0x21)
    }

    /// Master close mid-session: exactly ONE disconnect fires (kevent EOF and
    /// the 0.5s liveness probe must not double-report), the connection ends
    /// closed, and a follow-up close() stays a no-op.
    func testMasterCloseFiresExactlyOneDisconnect() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let name = ptsname(master) else {
            throw SerialError.io(errno: errno)
        }
        let conn = SerialConnection(path: String(cString: name),
                                    callbackQueue: DispatchQueue(label: "adv.cb"))
        try conn.open(settings: SerialSettings())

        let lock = NSLock()
        var disconnects = 0
        let first = expectation(description: "disconnect")
        conn.onDisconnect = {
            lock.lock()
            disconnects += 1
            if disconnects == 1 { first.fulfill() }
            lock.unlock()
        }
        close(master)
        wait(for: [first], timeout: 3)
        // Ride out two more liveness-timer periods hunting a double-fire.
        Thread.sleep(forTimeInterval: 1.2)
        lock.lock()
        XCTAssertEqual(disconnects, 1)
        lock.unlock()
        XCTAssertFalse(conn.isOpen)
        conn.close()
        conn.close()
        lock.lock()
        XCTAssertEqual(disconnects, 1)
        lock.unlock()
    }
}
