import XCTest
@testable import MemtermCore

final class SerialAdapterTests: XCTestCase {

    // MARK: journalState ↔ reconnectOffer round trip

    func testJournalStateRoundTrips() {
        let settings = SerialSettings(baud: 74880, dataBits: 7, parity: .even,
                                      stopBits: 2, flow: .rtscts)
        let state = SerialAdapter.journalState(
            path: "/dev/cu.usbserial-0001", identity: "usb:10c4:ea60:0001",
            label: "CP2102 USB to UART Bridge Controller",
            settings: settings, txLineEnding: .lf, localEcho: true)
        let offer = SerialAdapter.reconnectOffer(from: state)
        XCTAssertNotNil(offer)
        XCTAssertEqual(offer?.path, "/dev/cu.usbserial-0001")
        XCTAssertEqual(offer?.identity, "usb:10c4:ea60:0001")
        XCTAssertEqual(offer?.label, "CP2102 USB to UART Bridge Controller")
        XCTAssertEqual(offer?.settings, settings)
        XCTAssertEqual(offer?.txLineEnding, .lf)
        XCTAssertEqual(offer?.localEcho, true)
    }

    func testReconnectOfferDefaults() {
        // Minimal state (path + settings): identity falls back to the path,
        // tx to CRLF, echo off.
        let offer = SerialAdapter.reconnectOffer(from: [
            SerialAdapter.pathKey: "/dev/cu.usbmodem101",
            SerialAdapter.settingsKey: "9600-8N1",
        ])
        XCTAssertEqual(offer?.identity, "path:/dev/cu.usbmodem101")
        XCTAssertEqual(offer?.txLineEnding, .crlf)
        XCTAssertEqual(offer?.localEcho, false)
        XCTAssertEqual(offer?.settings.baud, 9600)
    }

    func testMalformedStateYieldsNoOffer() {
        XCTAssertNil(SerialAdapter.reconnectOffer(from: [:]))
        XCTAssertNil(SerialAdapter.reconnectOffer(from: [
            SerialAdapter.pathKey: "", SerialAdapter.settingsKey: "115200-8N1",
        ]))
        XCTAssertNil(SerialAdapter.reconnectOffer(from: [
            SerialAdapter.pathKey: "/dev/cu.x",
            SerialAdapter.settingsKey: "not-a-config",
        ]))
        XCTAssertNil(SerialAdapter.reconnectOffer(from: [
            SerialAdapter.pathKey: "/dev/cu.x",
        ]))
    }

    // MARK: Consent invariant — serial never yields a typed command

    func testResumeOfferReturnsNilForSerialAdapter() {
        // The reconnect is a UI ACTION, never a typed shell command: the
        // command-offer path must have nothing to say about 'serial', so the
        // FR-30 denylist precedence is untouched by construction.
        let snap = SnapshotRow(exe: "", argv: [], adapter: SerialAdapter.name,
                               adapterState: [
                                   SerialAdapter.pathKey: "/dev/cu.usbserial-0001",
                                   SerialAdapter.settingsKey: "115200-8N1",
                               ])
        XCTAssertNil(Adapters.resumeOffer(for: snap))
        XCTAssertNil(Adapters.resumeOffer(for: snap, cwdUnavailable: true))
    }

    // MARK: Names

    func testShortNameStripsDeviceNoise() {
        XCTAssertEqual(SerialAdapter.shortName(forPath: "/dev/cu.usbserial-0001"),
                       "usbserial-0001")
        XCTAssertEqual(SerialAdapter.shortName(forPath: "/dev/tty.usbmodem101"),
                       "usbmodem101")
        XCTAssertEqual(SerialAdapter.shortName(forPath: "/dev/ttys005"), "ttys005")
        XCTAssertEqual(SerialAdapter.shortName(forPath: "/dev/cu."), "cu.")
    }

    func testPaneTitleAndDisplayName() {
        XCTAssertEqual(SerialAdapter.paneTitle(path: "/dev/cu.usbserial-0001",
                                               baud: 115200),
                       "usbserial-0001 @ 115200")
        let offer = SerialAdapter.ReconnectOffer(
            path: "/dev/cu.usbserial-0001", identity: "x", label: "CP2102",
            settings: SerialSettings(), txLineEnding: .crlf, localEcho: false)
        XCTAssertEqual(offer.displayName, "usbserial-0001 @ 115200-8N1")
    }

    // MARK: TX line-ending transform

    func testLineEndingTransforms() {
        let input: [UInt8] = [0x70, 0x0D, 0x71]  // "p\rq"
        XCTAssertEqual(SerialLineEnding.cr.transformOutgoing(input), [0x70, 0x0D, 0x71])
        XCTAssertEqual(SerialLineEnding.lf.transformOutgoing(input), [0x70, 0x0A, 0x71])
        XCTAssertEqual(SerialLineEnding.crlf.transformOutgoing(input),
                       [0x70, 0x0D, 0x0A, 0x71])
        XCTAssertEqual(SerialLineEnding.none.transformOutgoing(input), [0x70, 0x71])
    }

    func testLineEndingLeavesControlBytesAlone() {
        // Ctrl-C (0x03) and LF pass through untouched under every ending —
        // serial panes have no signal semantics.
        for ending in SerialLineEnding.allCases {
            let out = ending.transformOutgoing([0x03, 0x0A, 0x1B])
            XCTAssertEqual(out, [0x03, 0x0A, 0x1B], "\(ending)")
        }
    }

    func testLineEndingConfigListsAligned() {
        XCTAssertEqual(SerialLineEnding.configValues.count, SerialLineEnding.labels.count)
        for raw in SerialLineEnding.configValues {
            XCTAssertNotNil(SerialLineEnding(rawValue: raw))
        }
        XCTAssertEqual(Config.serialLineEndings, SerialLineEnding.configValues)
    }
}
