import CProcShim
import Darwin
import Foundation

// Serial fd lifecycle (feature/serial stage 1). AppKit-free: opens a callout
// node (or a pty slave in tests), applies termios from SerialSettings, pumps
// reads through a DispatchSource — the same shape as SwiftTerm's
// LocalProcess loop, which is the seam a serial pane will bridge into.
//
// Ptys are the test double: they take full termios config (including
// arbitrary cfsetspeed values — macOS speed_t stores raw rates) but return
// ENOTTY for IOSSIOSPEED and every modem-line ioctl, so DTR/RTS/break paths
// throw `.lineControlUnsupported` gracefully rather than pretending.

public enum SerialError: Error, Equatable {
    case busy                      // EBUSY — someone else holds the port
    case vanished                  // ENOENT/ENXIO/ENODEV — device unplugged
    case permissionDenied          // EACCES/EPERM
    case notOpen
    case lineControlUnsupported    // ENOTTY — pty or adapter without modem lines
    case invalidSettings(String)
    case writeTimeout
    case io(errno: Int32)

    static func fromErrno(_ err: Int32) -> SerialError {
        switch err {
        case EBUSY: return .busy
        case ENOENT, ENXIO, ENODEV: return .vanished
        case EACCES, EPERM: return .permissionDenied
        case ENOTTY: return .lineControlUnsupported
        default: return .io(errno: err)
        }
    }
}

public struct SerialModemLines: Equatable {
    public let dtr: Bool
    public let rts: Bool
    public let cts: Bool
    public let carrierDetect: Bool
}

public final class SerialConnection {

    public let path: String

    /// Incoming bytes; fired on `callbackQueue`.
    public var onData: ((Data) -> Void)?
    /// Clean EOF from the peer (device unplugged / master side closed);
    /// the connection tears itself down first, then fires this once.
    public var onDisconnect: (() -> Void)?

    private let callbackQueue: DispatchQueue
    private let readQueue = DispatchQueue(label: "memterm.serial.read")
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var closed = false     // set once; close() is idempotent

    public init(path: String, callbackQueue: DispatchQueue = .main) {
        self.path = path
        self.callbackQueue = callbackQueue
    }

    deinit { close() }

    public var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return fd >= 0 && !closed
    }

    // MARK: Open / close

    /// Opens the node O_RDWR|O_NOCTTY|O_NONBLOCK (callout nodes ignore DCD;
    /// O_NONBLOCK both avoids a carrier wait and feeds the DispatchSource
    /// loop), applies `settings`, and starts the read pump. NEVER called
    /// without an explicit user gesture — restore offers type, not open.
    public func open(settings: SerialSettings) throws {
        lock.lock()
        guard fd < 0 && !closed else {
            lock.unlock()
            throw SerialError.io(errno: EALREADY)
        }
        let newFD = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard newFD >= 0 else {
            let err = errno
            lock.unlock()
            throw SerialError.fromErrno(err)
        }
        fd = newFD
        lock.unlock()

        do {
            try applyTermios(settings: settings, to: newFD)
        } catch {
            lock.lock()
            fd = -1
            closed = true
            lock.unlock()
            _ = Darwin.close(newFD)
            throw error
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: newFD, queue: readQueue)
        source.setEventHandler { [weak self] in self?.pumpReads(from: newFD) }
        // Cancel handler owns the close(2): it runs strictly after the last
        // event handler, so the fd can never be reused under a live read.
        source.setCancelHandler { _ = Darwin.close(newFD) }
        lock.lock()
        readSource = source
        lock.unlock()
        source.resume()
    }

    /// Idempotent: the first call cancels the source (whose cancel handler
    /// closes the fd); every later call is a no-op.
    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let source = readSource
        let openFD = fd
        readSource = nil
        fd = -1
        lock.unlock()
        if let source {
            source.cancel()
        } else if openFD >= 0 {
            _ = Darwin.close(openFD)
        }
    }

    // MARK: Read pump

    private func pumpReads(from fd: Int32) {
        var collected = Data()
        var sawEOF = false
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                collected.append(contentsOf: buf[0..<n])
                continue
            }
            if n == 0 { sawEOF = true }           // peer closed — disconnect
            break                                  // 0, EAGAIN, or error
        }
        if !collected.isEmpty, let handler = onData {
            let data = collected
            callbackQueue.async { handler(data) }
        }
        if sawEOF {
            close()
            if let handler = onDisconnect {
                callbackQueue.async { handler() }
            }
        }
    }

    // MARK: Write (with backpressure)

    /// Writes all of `data`, polling POLLOUT when the driver's buffer is
    /// full (O_NONBLOCK write returns EAGAIN). Throws `.writeTimeout` if the
    /// line stays blocked past `timeout` — backpressure surfaces instead of
    /// silently dropping bytes.
    public func write(_ data: Data, timeout: TimeInterval = 5.0) throws {
        let fd = try openFD()
        let deadline = Date(timeIntervalSinceNow: timeout)
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes {
                Darwin.write(fd, $0.baseAddress! + written, $0.count - written)
            }
            if n > 0 {
                written += n
                continue
            }
            let err = errno
            guard n < 0, err == EAGAIN || err == EINTR else {
                throw SerialError.io(errno: n < 0 ? err : EIO)
            }
            let msLeft = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard msLeft > 0 else { throw SerialError.writeTimeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = poll(&pfd, 1, min(msLeft, 100))
            if pr < 0 && errno != EINTR { throw SerialError.io(errno: errno) }
        }
    }

    // MARK: Settings

    /// Re-applies settings on the live fd (picocom-style on-the-fly baud
    /// change; also how reconnect restores a session's line config).
    public func apply(settings: SerialSettings) throws {
        try applyTermios(settings: settings, to: openFD())
    }

    /// Termios currently on the fd — used by tests for readback assertions.
    public func currentTermios() throws -> termios {
        let fd = try openFD()
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw SerialError.fromErrno(errno) }
        return t
    }

    private func applyTermios(settings: SerialSettings, to fd: Int32) throws {
        guard (5...8).contains(settings.dataBits) else {
            throw SerialError.invalidSettings("data bits \(settings.dataBits)")
        }
        guard (1...2).contains(settings.stopBits) else {
            throw SerialError.invalidSettings("stop bits \(settings.stopBits)")
        }
        guard settings.baud > 0 else {
            throw SerialError.invalidSettings("baud \(settings.baud)")
        }

        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { throw SerialError.fromErrno(errno) }
        cfmakeraw(&t)
        t.c_cflag |= UInt(CLOCAL | CREAD)

        t.c_cflag &= ~UInt(CSIZE)
        switch settings.dataBits {
        case 5: t.c_cflag |= UInt(CS5)
        case 6: t.c_cflag |= UInt(CS6)
        case 7: t.c_cflag |= UInt(CS7)
        default: t.c_cflag |= UInt(CS8)
        }

        t.c_cflag &= ~UInt(PARENB | PARODD)
        switch settings.parity {
        case .none: break
        case .even: t.c_cflag |= UInt(PARENB)
        case .odd: t.c_cflag |= UInt(PARENB | PARODD)
        }

        if settings.stopBits == 2 {
            t.c_cflag |= UInt(CSTOPB)
        } else {
            t.c_cflag &= ~UInt(CSTOPB)
        }

        t.c_cflag &= ~UInt(CRTSCTS)
        t.c_iflag &= ~UInt(IXON | IXOFF | IXANY)
        switch settings.flow {
        case .none: break
        case .rtscts: t.c_cflag |= UInt(CRTSCTS)
        case .xonxoff: t.c_iflag |= UInt(IXON | IXOFF)
        }

        if settings.isStandardBaud {
            _ = cfsetspeed(&t, speed_t(settings.baud))
            guard tcsetattr(fd, TCSANOW, &t) == 0 else {
                throw SerialError.fromErrno(errno)
            }
        } else {
            // Arbitrary rate: tcsetattr a nearby standard rate first, then
            // IOSSIOSPEED LAST (a later tcsetattr reverts the driver). Ptys
            // return ENOTTY for IOSSIOSPEED but happily store raw rates via
            // cfsetspeed — macOS speed_t is a raw value — so fall back.
            _ = cfsetspeed(&t, speed_t(settings.nearestStandardBaud))
            guard tcsetattr(fd, TCSANOW, &t) == 0 else {
                throw SerialError.fromErrno(errno)
            }
            if memterm_set_arbitrary_baud(fd, UInt(settings.baud)) != 0 {
                guard errno == ENOTTY else { throw SerialError.fromErrno(errno) }
                _ = cfsetspeed(&t, speed_t(settings.baud))
                guard tcsetattr(fd, TCSANOW, &t) == 0 else {
                    throw SerialError.fromErrno(errno)
                }
            }
        }
    }

    // MARK: Modem lines / break

    /// DTR/RTS/CTS/CD via TIOCMGET. Throws `.lineControlUnsupported` where
    /// the fd has no modem lines (ptys, some adapters) — callers degrade to
    /// hiding the controls, never to guessing.
    public func modemLines() throws -> SerialModemLines {
        let fd = try openFD()
        var bits: Int32 = 0
        guard ioctl(fd, UInt(TIOCMGET), &bits) == 0 else {
            throw SerialError.fromErrno(errno)
        }
        return SerialModemLines(dtr: bits & TIOCM_DTR != 0,
                                rts: bits & TIOCM_RTS != 0,
                                cts: bits & TIOCM_CTS != 0,
                                carrierDetect: bits & TIOCM_CD != 0)
    }

    /// Sets DTR/RTS explicitly. NEVER called implicitly on open — boards
    /// wired for auto-reset (Arduino DTR cap, ESP32 EN/IO0 transistors)
    /// reboot or hang when a terminal toggles lines behind the user's back.
    public func setModemLine(dtr: Bool? = nil, rts: Bool? = nil) throws {
        let fd = try openFD()
        var bits: Int32 = 0
        guard ioctl(fd, UInt(TIOCMGET), &bits) == 0 else {
            throw SerialError.fromErrno(errno)
        }
        if let dtr { bits = dtr ? bits | TIOCM_DTR : bits & ~TIOCM_DTR }
        if let rts { bits = rts ? bits | TIOCM_RTS : bits & ~TIOCM_RTS }
        guard ioctl(fd, UInt(TIOCMSET), &bits) == 0 else {
            throw SerialError.fromErrno(errno)
        }
    }

    /// tcsendbreak; a silent no-op on ptys (returns success there).
    public func sendBreak() throws {
        let fd = try openFD()
        guard tcsendbreak(fd, 0) == 0 else { throw SerialError.fromErrno(errno) }
    }

    // MARK: -

    private func openFD() throws -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0 && !closed else { throw SerialError.notOpen }
        return fd
    }
}
