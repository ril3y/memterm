import Darwin
import XCTest
@testable import MemtermCore

// SerialConnection end-to-end over pty pairs — the researched test double:
// ptys take full termios config (even arbitrary raw rates) but return ENOTTY
// for modem-line ioctls and IOSSIOSPEED, so line-control tests assert the
// GRACEFUL failure path. No real /dev/cu.* device is ever opened here.
final class SerialConnectionTests: XCTestCase {

    /// Pty pair holder; closing the master is idempotent so tests can close
    /// it mid-test (EOF scenarios) without a double-close on a reused fd.
    private final class PTY {
        let master: Int32
        let slavePath: String
        private var masterClosed = false

        init() throws {
            master = posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
                  let name = ptsname(master) else {
                throw SerialError.io(errno: errno)
            }
            slavePath = String(cString: name)
        }

        func closeMaster() {
            guard !masterClosed else { return }
            masterClosed = true
            close(master)
        }

        deinit { closeMaster() }
    }

    private func openPTY() throws -> PTY { try PTY() }

    /// Reads from the master with a poll timeout so a broken pump fails the
    /// test instead of hanging it.
    private func readMaster(_ fd: Int32, count: Int, timeout: TimeInterval = 2) -> [UInt8] {
        var out: [UInt8] = []
        let deadline = Date(timeIntervalSinceNow: timeout)
        var buf = [UInt8](repeating: 0, count: 4096)
        while out.count < count && Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 100) > 0 else { continue }
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]) }
        }
        return out
    }

    // MARK: Open + loopback

    func testOpenWriteReadLoopback() throws {
        let pty = try openPTY()
        let queue = DispatchQueue(label: "test.serial.cb")
        let conn = SerialConnection(path: pty.slavePath, callbackQueue: queue)
        defer { conn.close() }

        try conn.open(settings: SerialSettings())
        XCTAssertTrue(conn.isOpen)

        // TX: connection -> master
        try conn.write(Data("hello serial".utf8))
        XCTAssertEqual(readMaster(pty.master, count: 12),
                       [UInt8]("hello serial".utf8))

        // RX: master -> onData on the callback queue
        let got = expectation(description: "onData")
        var received = Data()
        conn.onData = { data in
            received.append(data)
            if received.count >= 11 { got.fulfill() }
        }
        write(pty.master, "from-device", 11)
        wait(for: [got], timeout: 2)
        XCTAssertEqual(received, Data("from-device".utf8))
    }

    func testOnTrafficReportsRxAndTxByteCounts() throws {
        // The footer-bar counter hook: write() reports TX bytes that reached
        // the fd, the read pump reports RX bytes, both on the callback queue.
        let pty = try openPTY()
        let queue = DispatchQueue(label: "test.serial.traffic")
        let conn = SerialConnection(path: pty.slavePath, callbackQueue: queue)
        defer { conn.close() }
        try conn.open(settings: SerialSettings())

        var rxTotal = 0, txTotal = 0
        let sawTx = expectation(description: "tx counted")
        let sawRx = expectation(description: "rx counted")
        var txFulfilled = false, rxFulfilled = false
        conn.onTraffic = { rx, tx in
            rxTotal += rx
            txTotal += tx
            if txTotal >= 12, !txFulfilled { txFulfilled = true; sawTx.fulfill() }
            if rxTotal >= 11, !rxFulfilled { rxFulfilled = true; sawRx.fulfill() }
        }

        try conn.write(Data("hello serial".utf8))          // 12 bytes TX
        _ = readMaster(pty.master, count: 12)
        wait(for: [sawTx], timeout: 2)
        XCTAssertEqual(txTotal, 12)
        XCTAssertEqual(rxTotal, 0)

        write(pty.master, "from-device", 11)               // 11 bytes RX
        wait(for: [sawRx], timeout: 2)
        XCTAssertEqual(rxTotal, 11)
        XCTAssertEqual(txTotal, 12)
    }

    func testTermiosAppliedAndReadBack() throws {
        let pty = try openPTY()
        let conn = SerialConnection(path: pty.slavePath,
                                    callbackQueue: DispatchQueue(label: "cb"))
        defer { conn.close() }
        try conn.open(settings: SerialSettings(baud: 115200, dataBits: 8,
                                               parity: .none, stopBits: 1,
                                               flow: .rtscts))
        var t = try conn.currentTermios()
        XCTAssertEqual(t.c_cflag & UInt(CSIZE), UInt(CS8))
        XCTAssertEqual(t.c_cflag & UInt(PARENB), 0)
        XCTAssertEqual(t.c_cflag & UInt(CSTOPB), 0)
        XCTAssertEqual(t.c_cflag & UInt(CRTSCTS), UInt(CRTSCTS))
        XCTAssertEqual(cfgetispeed(&t), 115200)
        XCTAssertEqual(cfgetospeed(&t), 115200)

        // On-the-fly reconfigure (picocom-style): 7E2 + xonxoff
        try conn.apply(settings: SerialSettings(baud: 9600, dataBits: 7,
                                                parity: .even, stopBits: 2,
                                                flow: .xonxoff))
        var t2 = try conn.currentTermios()
        XCTAssertEqual(t2.c_cflag & UInt(CSIZE), UInt(CS7))
        XCTAssertEqual(t2.c_cflag & UInt(PARENB), UInt(PARENB))
        XCTAssertEqual(t2.c_cflag & UInt(PARODD), 0)
        XCTAssertEqual(t2.c_cflag & UInt(CSTOPB), UInt(CSTOPB))
        XCTAssertEqual(t2.c_cflag & UInt(CRTSCTS), 0)
        XCTAssertEqual(t2.c_iflag & UInt(IXON | IXOFF), UInt(IXON | IXOFF))
        XCTAssertEqual(cfgetispeed(&t2), 9600)
    }

    func testArbitraryBaudFallsBackGracefullyOnPty() throws {
        // 74880 is non-standard: the real-driver path (IOSSIOSPEED) returns
        // ENOTTY on a pty, and the connection falls back to cfsetspeed with
        // the raw value — which macOS ptys store verbatim.
        let pty = try openPTY()
        let conn = SerialConnection(path: pty.slavePath,
                                    callbackQueue: DispatchQueue(label: "cb"))
        defer { conn.close() }
        try conn.open(settings: SerialSettings(baud: 74880))
        var t = try conn.currentTermios()
        XCTAssertEqual(cfgetispeed(&t), 74880)
    }

    // MARK: Modem lines / break — ENOTTY grace on ptys

    func testModemLineOpsDegradeGracefullyOnPty() throws {
        let pty = try openPTY()
        let conn = SerialConnection(path: pty.slavePath,
                                    callbackQueue: DispatchQueue(label: "cb"))
        defer { conn.close() }
        try conn.open(settings: SerialSettings())

        XCTAssertThrowsError(try conn.modemLines()) {
            XCTAssertEqual($0 as? SerialError, .lineControlUnsupported)
        }
        XCTAssertThrowsError(try conn.setModemLine(dtr: true)) {
            XCTAssertEqual($0 as? SerialError, .lineControlUnsupported)
        }
        XCTAssertThrowsError(try conn.setModemLine(rts: false)) {
            XCTAssertEqual($0 as? SerialError, .lineControlUnsupported)
        }
        // tcsendbreak is a silent no-op on ptys — succeeds.
        XCTAssertNoThrow(try conn.sendBreak())
    }

    // MARK: Errors

    func testOpenMissingDeviceThrowsVanished() {
        let conn = SerialConnection(path: "/dev/cu.memterm-test-nonexistent",
                                    callbackQueue: DispatchQueue(label: "cb"))
        XCTAssertThrowsError(try conn.open(settings: SerialSettings())) {
            XCTAssertEqual($0 as? SerialError, .vanished)
        }
        XCTAssertFalse(conn.isOpen)
    }

    func testWriteBeforeOpenAndAfterCloseThrowsNotOpen() throws {
        let pty = try openPTY()
        let conn = SerialConnection(path: pty.slavePath,
                                    callbackQueue: DispatchQueue(label: "cb"))
        XCTAssertThrowsError(try conn.write(Data([1]))) {
            XCTAssertEqual($0 as? SerialError, .notOpen)
        }
        try conn.open(settings: SerialSettings())
        conn.close()
        XCTAssertThrowsError(try conn.write(Data([1]))) {
            XCTAssertEqual($0 as? SerialError, .notOpen)
        }
    }

    // MARK: Close / teardown

    func testCloseIsIdempotent() throws {
        let pty = try openPTY()
        let conn = SerialConnection(path: pty.slavePath,
                                    callbackQueue: DispatchQueue(label: "cb"))
        try conn.open(settings: SerialSettings())
        conn.close()
        conn.close()
        conn.close()
        XCTAssertFalse(conn.isOpen)
        XCTAssertThrowsError(try conn.sendBreak()) {
            XCTAssertEqual($0 as? SerialError, .notOpen)
        }
    }

    func testPeerCloseDeliversEOFDisconnect() throws {
        let pty = try openPTY()
        let conn = SerialConnection(path: pty.slavePath,
                                    callbackQueue: DispatchQueue(label: "cb"))
        defer { conn.close() }
        try conn.open(settings: SerialSettings())

        let disconnected = expectation(description: "onDisconnect")
        conn.onDisconnect = { disconnected.fulfill() }
        pty.closeMaster()   // device side vanishes -> read() returns 0
        wait(for: [disconnected], timeout: 2)
        XCTAssertFalse(conn.isOpen)
    }

    func testTeardownLeaksNoFileDescriptors() throws {
        func openFDCount() -> Int {
            var n = 0
            for fd in 0..<getdtablesize() where fcntl(fd, F_GETFD) != -1 { n += 1 }
            return n
        }

        // Warmup: let libdispatch allocate its long-lived internal fds.
        for _ in 0..<2 {
            let pty = try openPTY()
            let conn = SerialConnection(path: pty.slavePath,
                                        callbackQueue: DispatchQueue(label: "cb"))
            try conn.open(settings: SerialSettings())
            conn.close()
            pty.closeMaster()
        }
        Thread.sleep(forTimeInterval: 0.2)

        let before = openFDCount()
        for i in 0..<10 {
            let pty = try openPTY()
            let conn = SerialConnection(path: pty.slavePath,
                                        callbackQueue: DispatchQueue(label: "cb-\(i)"))
            try conn.open(settings: SerialSettings())
            try conn.write(Data("ping".utf8))
            _ = readMaster(pty.master, count: 4)
            conn.close()
            pty.closeMaster()
        }
        // Cancel handlers (which own the close(2)) run async; give them a beat.
        Thread.sleep(forTimeInterval: 0.3)
        let after = openFDCount()
        XCTAssertLessThanOrEqual(after, before,
                                 "fd leak: \(before) before, \(after) after")
    }
}
