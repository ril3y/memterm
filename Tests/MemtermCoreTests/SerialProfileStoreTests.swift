import XCTest
@testable import MemtermCore

final class SerialProfileStoreTests: XCTestCase {

    private var tempDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("state.db")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testProfileRoundTrip() {
        let store = StateStore(url: dbURL)
        let profile = SerialProfileRow(identity: "usb:10c4:ea60:0001",
                                       settings: "74880-7E2-rtscts",
                                       txLineEnding: "lf", localEcho: true,
                                       lastPath: "/dev/cu.usbserial-0001",
                                       label: "CP2102 USB to UART Bridge Controller")
        store.upsertSerialProfile(profile)
        store.barrier()
        XCTAssertEqual(store.serialProfile(identity: "usb:10c4:ea60:0001"), profile)
        XCTAssertNil(store.serialProfile(identity: "usb:0000:0000:none"))
    }

    func testProfileUpsertReplaces() {
        let store = StateStore(url: dbURL)
        var profile = SerialProfileRow(identity: "loc:14100000", settings: "9600-8N1",
                                       txLineEnding: "crlf", localEcho: false,
                                       lastPath: "/dev/cu.usbserial-A", label: "CH340")
        store.upsertSerialProfile(profile)
        profile.settings = "115200-8N1"
        profile.lastPath = "/dev/cu.usbserial-B"  // /dev renumbered; identity stable
        store.upsertSerialProfile(profile)
        store.barrier()
        let loaded = store.serialProfile(identity: "loc:14100000")
        XCTAssertEqual(loaded?.settings, "115200-8N1")
        XCTAssertEqual(loaded?.lastPath, "/dev/cu.usbserial-B")
    }

    func testProfilesSurviveReopen() {
        // The profile is journal state: a fresh StateStore on the same file
        // (relaunch) must still know the device.
        do {
            let store = StateStore(url: dbURL)
            store.upsertSerialProfile(SerialProfileRow(
                identity: "usb:1a86:7523:", settings: "115200-8N1",
                txLineEnding: "crlf", localEcho: false,
                lastPath: "/dev/cu.usbserial-110", label: "USB Serial"))
            store.barrier()
        }
        let reopened = StateStore(url: dbURL)
        let loaded = reopened.serialProfile(identity: "usb:1a86:7523:")
        XCTAssertEqual(loaded?.settings, "115200-8N1")
        XCTAssertEqual(loaded?.label, "USB Serial")
    }

    func testSerialSnapshotRoundTripsThroughTopology() {
        // The 'serial' adapter row must survive the whole-topology rewrite +
        // loadState exactly like process adapters do.
        let store = StateStore(url: dbURL)
        let tab = TabSnap(id: "t1", title: "", tree: .pane("p1"), panes: [
            PaneSnap(id: "p1", shell: nil, cwd: nil, cwdSource: nil),
        ])
        store.saveTopology([WindowSnap(id: "w1", frame: "0,0,800,600",
                                       focusedTab: "t1", tabs: [tab])])
        let state = SerialAdapter.journalState(
            path: "/dev/cu.usbserial-0001", identity: "usb:10c4:ea60:0001",
            label: "CP2102", settings: SerialSettings(),
            txLineEnding: .crlf, localEcho: false)
        store.upsertSnapshot("p1", exe: "", argv: [], pid: 0, procStart: 0,
                             adapter: SerialAdapter.name, adapterState: state)
        store.barrier()
        let windows = store.loadState()
        let snap = windows.first?.tabs.first?.panes["p1"]?.snapshot
        XCTAssertEqual(snap?.adapter, SerialAdapter.name)
        let offer = snap.flatMap { SerialAdapter.reconnectOffer(from: $0.adapterState) }
        XCTAssertEqual(offer?.displayName, "usbserial-0001 @ 115200-8N1")
    }
}
