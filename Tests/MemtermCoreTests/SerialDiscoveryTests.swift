import XCTest
@testable import MemtermCore

// Discovery smoke: READ-ONLY IORegistry enumeration. Never opens, writes to,
// or reconfigures a device node — connected hardware must not be disturbed.
final class SerialDiscoveryTests: XCTestCase {

    func testEnumerateIsReadOnlyAndWellFormed() {
        let ports = SerialPortDiscovery.enumeratePorts()
        // Machines without serial hardware still usually expose
        // Bluetooth/debug ports; an empty list is legal, not a failure.
        for port in ports {
            XCTAssertTrue(port.path.hasPrefix("/dev/cu."), port.path)
            XCTAssertFalse(port.label.isEmpty, port.path)
            XCTAssertFalse(port.stableIdentity.isEmpty, port.path)
            if let dialin = port.dialinPath {
                XCTAssertTrue(dialin.hasPrefix("/dev/tty."), dialin)
            }
        }
        // Paths are unique — one info per callout node.
        XCTAssertEqual(Set(ports.map(\.path)).count, ports.count)
    }

    func testUSBSerialAdaptersCarryMetadata() throws {
        let ports = SerialPortDiscovery.enumeratePorts()
        let usbLike = ports.filter {
            $0.path.contains("usbserial") || $0.path.contains("usbmodem")
        }
        guard !usbLike.isEmpty else {
            throw XCTSkip("no USB serial adapters attached")
        }
        for port in usbLike {
            // Every USB-backed port must yield SOME identity stronger than
            // its volatile /dev path (vid/pid/serial, or locationID for
            // serial-less CH340-class clones).
            XCTAssertTrue(port.isUSB, port.path)
            XCTAssertFalse(port.stableIdentity.hasPrefix("path:"),
                           "\(port.path) fell back to path identity")
            XCTAssertFalse(port.label.isEmpty, port.path)
        }
        // The founder's CP2102 (/dev/cu.usbserial-0001 pattern) carries a
        // USB serial number, so its identity must be the strongest form.
        if let cp2102 = usbLike.first(where: { $0.path.contains("usbserial-0001") }) {
            XCTAssertTrue(cp2102.stableIdentity.hasPrefix("usb:"),
                          cp2102.stableIdentity)
            XCTAssertNotNil(cp2102.usbProductName)
        }
    }

    func testStableIdentityPrefersSerialThenLocationThenPath() {
        let full = SerialPortInfo(path: "/dev/cu.usbserial-0001",
                                  usbProductName: "CP2102 USB to UART Bridge Controller",
                                  usbSerialNumber: "0001",
                                  vendorID: 0x10C4, productID: 0xEA60,
                                  locationID: 0x0210_0000)
        XCTAssertEqual(full.stableIdentity, "usb:10c4:ea60:0001")
        XCTAssertEqual(full.label, "CP2102 USB to UART Bridge Controller")

        // CH340-class clone: product name but no vendor string, no serial.
        let clone = SerialPortInfo(path: "/dev/cu.usbserial-11310",
                                   usbProductName: "USB Serial",
                                   vendorID: 0x1A86, productID: 0x7523,
                                   locationID: 0x0113_1000)
        XCTAssertEqual(clone.stableIdentity, "loc:01131000")
        XCTAssertEqual(clone.label, "USB Serial")

        // Non-USB (Bluetooth/debug) port: no metadata at all.
        let bare = SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port")
        XCTAssertEqual(bare.stableIdentity, "path:/dev/cu.Bluetooth-Incoming-Port")
        XCTAssertEqual(bare.label, "cu.Bluetooth-Incoming-Port")
        XCTAssertFalse(bare.isUSB)
    }

    func testHotplugWatcherRegistersAndDrainsExistingPorts() {
        let watcher = SerialHotplugWatcher(callbackQueue: DispatchQueue(label: "hp"))
        let existing = watcher.start()
        // Registration must succeed and deliver the pre-existing set (which
        // may legitimately be empty on a bare machine).
        XCTAssertNotNil(existing)
        if let existing, !existing.isEmpty {
            XCTAssertTrue(existing.allSatisfy { $0.path.hasPrefix("/dev/") })
        }
        // Second start is a no-op while running.
        XCTAssertNil(watcher.start())
        watcher.stop()
        watcher.stop()   // idempotent
        // Restartable after stop.
        XCTAssertNotNil(watcher.start())
        watcher.stop()
    }
}
