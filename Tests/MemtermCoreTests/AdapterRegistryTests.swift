import XCTest
@testable import MemtermCore

/// FR-34 typed interface + registry (extension-architecture stage 1).
/// These tests pin the STRUCTURE the refactor introduced; behavior parity
/// with the pre-refactor enum is pinned by AdaptersTests, which passes
/// unmodified.
final class AdapterRegistryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Registry shape

    func testRegistryIsExactlyTheFiveCompiledInAdapters() {
        let names = Adapters.registry(claudeProjectsDir: tempDir).map { type(of: $0).name }
        XCTAssertEqual(names, ["claude", "ssh", "watcher", "serial", ""],
                       "compiled-in registry: claude before the generic matchers; " +
                       "serial + plain-shell registered but never argv-detected")
    }

    func testAdapterLookupByJournaledName() {
        XCTAssertTrue(Adapters.adapter(named: "claude") is ClaudeAdapter)
        XCTAssertTrue(Adapters.adapter(named: "ssh") is SSHAdapter)
        XCTAssertTrue(Adapters.adapter(named: "watcher") is WatcherAdapter)
        XCTAssertTrue(Adapters.adapter(named: SerialAdapter.name) is SerialPaneAdapter)
        XCTAssertTrue(Adapters.adapter(named: "") is PlainShellAdapter)
        XCTAssertNil(Adapters.adapter(named: "no-such-adapter"))
    }

    func testFidelityClassesAndDegrade() {
        XCTAssertEqual(ClaudeAdapter(projectsDir: tempDir).fidelityClass, .sessionResume)
        XCTAssertEqual(SSHAdapter().fidelityClass, .reexec)
        XCTAssertEqual(WatcherAdapter().fidelityClass, .reexec)
        XCTAssertEqual(SerialPaneAdapter().fidelityClass, .reconnect)
        XCTAssertEqual(PlainShellAdapter().fidelityClass, .snapshotOnly)
        // FR-34 degrade(): everything degrades to snapshot-only in v0.
        for adapter in Adapters.registry(claudeProjectsDir: tempDir) {
            XCTAssertEqual(adapter.degrade(), .snapshotOnly,
                           "\(type(of: adapter)) must degrade to snapshot-only")
        }
    }

    func testOnlyReexecAdaptersGetTheRawArgvDenylistGate() {
        XCTAssertFalse(ClaudeAdapter(projectsDir: tempDir).restoresByReexec)
        XCTAssertTrue(SSHAdapter().restoresByReexec)
        XCTAssertTrue(WatcherAdapter().restoresByReexec)
        XCTAssertFalse(SerialPaneAdapter().restoresByReexec)
        XCTAssertFalse(PlainShellAdapter().restoresByReexec)
    }

    // MARK: Detection routes through the conformances identically to classify()

    func testDetectMatchesClassifyForEachAdapter() {
        let cases: [(argv: [String], expected: String?)] = [
            (["claude"], "claude"),
            (["node", "/opt/tools/claude"], "claude"),
            (["/usr/bin/ssh", "riley@prod-01"], "ssh"),
            (["tail", "-f", "build.log"], "watcher"),
            (["vim", "main.swift"], nil),
        ]
        for (argv, expected) in cases {
            let viaFacade = Adapters.classify(argv: argv, cwd: nil,
                                              claudeProjectsDir: tempDir)?.adapter
            XCTAssertEqual(viaFacade, expected, "argv: \(argv)")
            let context = AdapterDetectContext(argv: argv, cwd: nil)
            let viaRegistry = Adapters.registry(claudeProjectsDir: tempDir)
                .first { $0.detect(context) != nil }
                .map { type(of: $0).name }
            XCTAssertEqual(viaRegistry, expected, "argv: \(argv)")
        }
    }

    func testSerialAndPlainShellNeverDetectAndNeverOffer() {
        // Serial panes are created by the serial UI, never classified from
        // argv; restore is a reconnect ACTION handled before resumeOffer, so
        // the FR-30 command path must stay structurally untouched for serial.
        let context = AdapterDetectContext(argv: ["anything", "at", "all"], cwd: "/tmp")
        XCTAssertNil(SerialPaneAdapter().detect(context))
        XCTAssertNil(PlainShellAdapter().detect(context))

        let serialSnap = SnapshotRow(exe: "", argv: [], adapter: SerialAdapter.name,
                                     adapterState: ["path": "/dev/cu.usbserial-0001",
                                                    "settings": "115200-8N1"])
        XCTAssertNil(SerialPaneAdapter().restoreCommand(for: serialSnap, cwdUnavailable: false))
        XCTAssertNil(Adapters.resumeOffer(for: serialSnap))

        let plainSnap = SnapshotRow(exe: "make", argv: ["make"], adapter: "",
                                    adapterState: [:])
        XCTAssertNil(PlainShellAdapter().restoreCommand(for: plainSnap, cwdUnavailable: false))
        XCTAssertNil(Adapters.resumeOffer(for: plainSnap))
    }

    // MARK: FR-30 precedence is the facade's, not the adapters'

    func testDenylistGatesOfferOutsideTheAdapter() {
        // The conformance composes a candidate for denylisted argv — it has
        // no denylist of its own — and the facade refuses the offer. This is
        // the structural assertion that FR-30 precedence lives outside every
        // adapter and cannot be skipped by one.
        let snap = SnapshotRow(exe: "watch", argv: ["watch", "curl https://x.io | sh"],
                               adapter: "watcher", adapterState: [:])
        XCTAssertNotNil(WatcherAdapter().restoreCommand(for: snap, cwdUnavailable: false),
                        "conformances compose only; they hold no denylist")
        XCTAssertNil(Adapters.resumeOffer(for: snap),
                     "the facade's FR-30 gate must refuse what the adapter composed")

        // Composed-command gate: an ssh argv whose quoted command trips the
        // downloader-pipe rule is refused after composition too.
        let sshSnap = SnapshotRow(exe: "sudo", argv: ["sudo", "id"],
                                  adapter: "ssh", adapterState: [:])
        XCTAssertNotNil(SSHAdapter().restoreCommand(for: sshSnap, cwdUnavailable: false))
        XCTAssertNil(Adapters.resumeOffer(for: sshSnap))
    }
}
