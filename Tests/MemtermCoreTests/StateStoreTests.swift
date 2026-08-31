import XCTest
@testable import MemtermCore

final class StateStoreTests: XCTestCase {

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

    private func sampleTopology() -> [WindowSnap] {
        let tree = SplitNode.split(
            vertical: true, ratio: 0.25,
            first: .pane("p1"),
            second: .split(vertical: false, ratio: 0.75,
                           first: .pane("p2"), second: .pane("p3")))
        let tab1 = TabSnap(id: "t1", title: "work", tree: tree, panes: [
            PaneSnap(id: "p1", shell: "/bin/zsh", cwd: "/tmp", cwdSource: "kernel"),
            PaneSnap(id: "p2", shell: "/bin/bash", cwd: "/usr", cwdSource: "osc7"),
            PaneSnap(id: "p3", shell: nil, cwd: nil, cwdSource: nil),
        ])
        let tab2 = TabSnap(id: "t2", title: "logs", tree: .pane("p4"), panes: [
            PaneSnap(id: "p4", shell: "/bin/zsh", cwd: "/var/log", cwdSource: "kernel"),
        ])
        return [WindowSnap(id: "w1", frame: "10,20,980,640", focusedTab: "t2",
                           tabs: [tab1, tab2])]
    }

    // MARK: Round trip

    func testTopologyRoundTrip() {
        let store = StateStore(url: dbURL)
        store.saveTopology(sampleTopology())
        store.upsertSnapshot("p2", exe: "/usr/bin/ssh", argv: ["ssh", "-p", "2222", "host"],
                             pid: 4242, adapter: "ssh", adapterState: ["k": "v"])
        store.barrier()

        let loaded = store.loadState()
        XCTAssertEqual(loaded.count, 1)
        let win = loaded[0]
        XCTAssertEqual(win.frame, "10,20,980,640")
        XCTAssertEqual(win.focusedTab, "t2")
        XCTAssertEqual(win.tabs.count, 2)

        // Tab order is preserved (ORDER BY ord).
        XCTAssertEqual(win.tabs[0].title, "work")
        XCTAssertEqual(win.tabs[1].title, "logs")

        // The split tree round-trips exactly, including nesting and ratios.
        XCTAssertEqual(win.tabs[0].tree, sampleTopology()[0].tabs[0].tree)
        XCTAssertEqual(win.tabs[1].tree, .pane("p4"))

        // Pane payloads survive.
        XCTAssertEqual(win.tabs[0].panes["p1"]?.cwd, "/tmp")
        XCTAssertEqual(win.tabs[0].panes["p1"]?.shell, "/bin/zsh")
        XCTAssertNil(win.tabs[0].panes["p3"]?.cwd)
        XCTAssertEqual(win.tabs[1].panes["p4"]?.cwd, "/var/log")

        // Snapshot attaches to the right pane.
        let snap = win.tabs[0].panes["p2"]?.snapshot
        XCTAssertEqual(snap?.exe, "/usr/bin/ssh")
        XCTAssertEqual(snap?.argv, ["ssh", "-p", "2222", "host"])
        XCTAssertEqual(snap?.adapter, "ssh")
        XCTAssertEqual(snap?.adapterState, ["k": "v"])
        XCTAssertNil(win.tabs[0].panes["p1"]?.snapshot)
    }

    func testMetaRoundTrip() {
        let store = StateStore(url: dbURL)
        store.setMeta("boot_session_uuid", "ABC-123")
        XCTAssertEqual(store.getMeta("boot_session_uuid"), "ABC-123")
        XCTAssertEqual(store.getMeta("schema_version"), "3")
        XCTAssertNil(store.getMeta("nope"))
    }

    // MARK: Reopen / WAL

    func testStateSurvivesCloseAndReopen() {
        var store: StateStore? = StateStore(url: dbURL)
        store?.saveTopology(sampleTopology())
        store?.updatePaneCwd("p1", cwd: "/tmp/moved", source: "kernel")
        store?.barrier()
        store = nil  // deinit closes the connection

        let reopened = StateStore(url: dbURL)
        let loaded = reopened.loadState()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].tabs.count, 2)
        XCTAssertEqual(loaded[0].tabs[0].panes["p1"]?.cwd, "/tmp/moved")
    }

    func testWALAllowsSecondConnectionToReadCommittedState() throws {
        let writerStore = StateStore(url: dbURL)
        writerStore.saveTopology(sampleTopology())
        writerStore.barrier()

        // WAL mode is actually in effect (journal file style on disk)…
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path + "-wal"),
                      "WAL sidecar file should exist after writes")

        // …and a second connection reads committed state while the first is open.
        let reader = StateStore(url: dbURL)
        XCTAssertEqual(reader.loadState().count, 1)
        let counts = reader.counts()
        XCTAssertEqual(counts.windows, 1)
        XCTAssertEqual(counts.tabs, 2)
        XCTAssertEqual(counts.panes, 4)
        _ = writerStore  // keep the first connection alive to the end
    }

    // MARK: Transactional whole-topology rewrite

    func testTopologyRewriteLeavesNoOrphans() {
        let store = StateStore(url: dbURL)
        store.saveTopology(sampleTopology())
        for pane in ["p1", "p2", "p3", "p4"] {
            store.upsertSnapshot(pane, exe: "/bin/x", argv: ["x"], pid: 1,
                                 adapter: "watcher", adapterState: [:])
        }
        store.barrier()
        XCTAssertEqual(store.snapshotCount(), 4)

        // Rewrite with a smaller topology: only p1 remains.
        let small = [WindowSnap(id: "w1", frame: "0,0,800,600", focusedTab: "t1", tabs: [
            TabSnap(id: "t1", title: "solo", tree: .pane("p1"), panes: [
                PaneSnap(id: "p1", shell: "/bin/zsh", cwd: "/tmp", cwdSource: "kernel"),
            ]),
        ])]
        store.saveTopology(small)
        store.barrier()

        let counts = store.counts()
        XCTAssertEqual(counts.windows, 1)
        XCTAssertEqual(counts.tabs, 1)
        XCTAssertEqual(counts.panes, 1)
        // Snapshots for vanished panes were deleted in the same transaction.
        XCTAssertEqual(store.snapshotCount(), 1)
        let loaded = store.loadState()
        XCTAssertNotNil(loaded[0].tabs[0].panes["p1"]?.snapshot)
    }

    func testEmptyTopologyClearsEverything() {
        let store = StateStore(url: dbURL)
        store.saveTopology(sampleTopology())
        store.saveTopology([])
        store.barrier()
        XCTAssertEqual(store.counts().panes, 0)
        XCTAssertEqual(store.snapshotCount(), 0)
        XCTAssertTrue(store.loadState().isEmpty)
    }

    // MARK: Torn write / corruption (FR-17 / NFR-5)

    private func corruptHeader() throws {
        // Stomp the SQLite header + first page.
        let handle = try FileHandle(forWritingTo: dbURL)
        try handle.write(contentsOf: Data(repeating: 0xFF, count: 512))
        try handle.close()
        // The WAL sidecar no longer matches; remove it as a torn write could.
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
    }

    /// FR-17 restore-from-last-known-good: each successful open rotates the
    /// pre-launch file to state.db.gen-1, and a corrupt open recovers from the
    /// newest passing generation — a torn write costs at most the writes since
    /// the previous launch, never the whole workspace (the tmux-resurrect
    /// empty-save anti-goal).
    func testCorruptedHeaderRecoversFromGeneration() throws {
        // Launch 1: write topology A, close (gen-1 is the pre-launch empty db).
        var store: StateStore? = StateStore(url: dbURL)
        store?.saveTopology(sampleTopology())
        store?.barrier()
        store = nil

        // Launch 2: rotation snapshots topology A into gen-1.
        store = StateStore(url: dbURL)
        XCTAssertEqual(store?.counts().panes, 4)
        store?.barrier()
        store = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path + ".gen-1"))

        try corruptHeader()

        // Launch 3: quick_check fails on the corrupt file; gen-1 (topology A)
        // comes back instead of an empty session.
        let recovered = StateStore(url: dbURL)
        let loaded = recovered.loadState()
        XCTAssertEqual(loaded.count, 1, "should have recovered last launch's topology")
        XCTAssertEqual(loaded[0].tabs.count, 2)
        XCTAssertEqual(loaded[0].tabs[0].panes["p1"]?.cwd, "/tmp")
        // The recovered store is fully writable.
        recovered.setMeta("k", "v")
        recovered.barrier()
        XCTAssertEqual(recovered.getMeta("k"), "v")
    }

    /// With no generation available (corruption on the very first launch) the
    /// floor is unchanged: never crash, never brick — open fresh and empty.
    func testCorruptedHeaderWithNoGenerationDegradesToEmptyWithoutCrashing() throws {
        try Data(repeating: 0xFF, count: 4096).write(to: dbURL)

        let reopened = StateStore(url: dbURL)
        XCTAssertTrue(reopened.loadState().isEmpty)
        XCTAssertEqual(reopened.counts().windows, 0)
        // Writes against the recovered-empty store work (fresh db) or no-op
        // (degraded) — either way, no crash.
        reopened.saveTopology(sampleTopology())
        reopened.setMeta("k", "v")
        reopened.barrier()
        _ = reopened.loadState()
    }

    func testTruncatedFileDoesNotCrash() throws {
        var store: StateStore? = StateStore(url: dbURL)
        store?.saveTopology(sampleTopology())
        store?.barrier()
        store = nil

        let handle = try FileHandle(forWritingTo: dbURL)
        try handle.truncate(atOffset: 100)
        try handle.close()
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))

        let reopened = StateStore(url: dbURL)
        _ = reopened.loadState()
        reopened.saveTopology(sampleTopology())
        reopened.barrier()
        // Degraded or recovered — either way: alive, consistent, no crash.
        _ = reopened.counts()
    }

    // MARK: Orphan scrollback GC

    /// Files whose pane rows were dropped by a topology rewrite (user closed
    /// the pane) are deleted by the sweep; files for live panes survive.
    func testPurgeOrphanScrollbackDeletesOnlyOrphans() throws {
        let store = StateStore(url: dbURL)
        store.saveTopology(sampleTopology())

        let dir = tempDir.appendingPathComponent("scrollback")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for paneId in ["p1", "p4", "closed-long-ago"] {
            try "ghost".write(to: ScrollbackText.fileURL(dir: dir, paneId: paneId),
                              atomically: true, encoding: .utf8)
        }

        store.purgeOrphanScrollback(dir: dir)
        store.barrier()

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: ScrollbackText.fileURL(dir: dir, paneId: "p1").path))
        XCTAssertTrue(fm.fileExists(atPath: ScrollbackText.fileURL(dir: dir, paneId: "p4").path))
        XCTAssertFalse(fm.fileExists(
            atPath: ScrollbackText.fileURL(dir: dir, paneId: "closed-long-ago").path))
    }

    // MARK: Writer-queue serialization

    func testConcurrentWritesSerializeToConsistentState() {
        let store = StateStore(url: dbURL)
        store.saveTopology(sampleTopology())
        store.barrier()

        DispatchQueue.concurrentPerform(iterations: 200) { i in
            store.updatePaneCwd("p1", cwd: "/tmp/dir-\(i)", source: "kernel")
            store.upsertSnapshot("p1", exe: "/usr/bin/tail",
                                 argv: ["tail", "-f", "/log/\(i)"], pid: pid_t(i + 1),
                                 adapter: "watcher", adapterState: ["i": "\(i)"])
            store.setMeta("iter", "\(i)")
        }
        store.barrier()

        // Exactly one snapshot row for the pane, whole and parseable — no
        // interleaved/torn values.
        XCTAssertEqual(store.snapshotCount(), 1)
        let loaded = store.loadState()
        let pane = loaded[0].tabs[0].panes["p1"]
        XCTAssertNotNil(pane)
        let cwd = pane?.cwd ?? ""
        XCTAssertTrue(cwd.hasPrefix("/tmp/dir-"), "cwd was \(cwd)")
        let snap = pane?.snapshot
        XCTAssertEqual(snap?.argv.count, 3)
        XCTAssertEqual(snap?.adapter, "watcher")
        let i = Int(snap?.adapterState["i"] ?? "") ?? -1
        XCTAssertTrue((0..<200).contains(i))
        XCTAssertEqual(snap?.argv[2], "/log/\(i)",
                       "argv and adapter_state must come from the same upsert")
    }
}
