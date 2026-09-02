import XCTest
@testable import MemtermCore

// The ~/.claude project/session scanner behind the ExtensionKit claude.*
// surface (kit v0). Fixture worlds are synthetic ~/.claude trees built per
// test; the last test is a READ-ONLY smoke against the real ~/.claude (it
// only lists and reads — never writes) asserting the undocumented real-world
// format parses without error.

final class ClaudeSessionScanTests: XCTestCase {
    private var root: URL!
    private var projectsDir: URL!
    private var sessionsDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-scan-\(UUID().uuidString)")
        projectsDir = root.appendingPathComponent("projects")
        sessionsDir = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: projectsDir,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture helpers

    @discardableResult
    private func writeSession(slug: String, id: String, lines: [String],
                              mtime: Date? = nil) throws -> URL {
        let dir = projectsDir.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime],
                                                  ofItemAtPath: url.path)
        }
        return url
    }

    private func writeRegistry(pid: Int32, sessionId: String, cwd: String? = "/tmp/proj",
                               version: String? = "2.1.999") throws {
        var record: [String: Any] = ["pid": Int(pid), "sessionId": sessionId]
        if let cwd { record["cwd"] = cwd }
        if let version { record["version"] = version }
        let data = try JSONSerialization.data(withJSONObject: record)
        try data.write(to: sessionsDir.appendingPathComponent("\(pid).json"))
    }

    /// A pid that is certainly not a running process (beyond macOS pid_max).
    private let deadPid: Int32 = 999_999

    // MARK: - Projects

    func testProjectScanCountsSessionsAndSortsByActivity() throws {
        let old = Date(timeIntervalSinceNow: -3600)
        try writeSession(slug: "proj-old", id: "aaaaaaaa-1111", lines: ["{}"], mtime: old)
        try writeSession(slug: "proj-new", id: "bbbbbbbb-2222", lines: ["{}"])
        try writeSession(slug: "proj-new", id: "cccccccc-3333", lines: ["{}"])
        // A project dir with no jsonls still lists with count 0.
        try FileManager.default.createDirectory(
            at: projectsDir.appendingPathComponent("proj-empty"),
            withIntermediateDirectories: true)
        // A stray FILE at the top level is not a project.
        try "x".write(to: projectsDir.appendingPathComponent("stray.jsonl"),
                      atomically: true, encoding: .utf8)

        let scans = Adapters.claudeProjectScans(projectsDir: projectsDir)
        XCTAssertEqual(scans.count, 3)
        XCTAssertEqual(scans[0].slug, "proj-new")
        XCTAssertEqual(scans[0].sessionCount, 2)
        XCTAssertEqual(scans[1].slug, "proj-old")
        XCTAssertEqual(scans[1].sessionCount, 1)
        XCTAssertEqual(scans[2].slug, "proj-empty")
        XCTAssertEqual(scans[2].sessionCount, 0)
        XCTAssertNil(scans[2].lastActivity)
    }

    func testProjectScanMissingDirYieldsEmpty() {
        let gone = root.appendingPathComponent("nonexistent")
        XCTAssertEqual(Adapters.claudeProjectScans(projectsDir: gone), [])
    }

    // MARK: - Sessions: identity, ordering, filtering

    func testSessionScanSortsNewestFirstAndSkipsInvalidNames() throws {
        let old = Date(timeIntervalSinceNow: -1800)
        try writeSession(slug: "p", id: "old-session", lines: ["{}"], mtime: old)
        try writeSession(slug: "p", id: "new-session", lines: ["{}"])
        // Invalid session-id filenames (shell metacharacters / leading dash)
        // never surface.
        try writeSession(slug: "p", id: "bad;id", lines: ["{}"])
        // Non-jsonl files and subdirectories are ignored.
        let dir = projectsDir.appendingPathComponent("p")
        try "x".write(to: dir.appendingPathComponent("notes.txt"),
                      atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("subdir"),
                                                withIntermediateDirectories: true)

        let scans = Adapters.claudeSessionScans(projectSlug: "p",
                                                projectsDir: projectsDir,
                                                sessionsDir: sessionsDir)
        XCTAssertEqual(scans.map(\.id), ["new-session", "old-session"])
        XCTAssertEqual(scans.map(\.projectSlug), ["p", "p"])
    }

    // MARK: - Liveness (the ~/.claude/sessions/<pid>.json registry)

    func testLivenessFromRegistryWithAlivePid() throws {
        try writeSession(slug: "p", id: "live-session", lines: ["{}"])
        try writeSession(slug: "p", id: "dead-session", lines: ["{}"])
        // Our own pid is certainly alive; the dead pid certainly is not.
        try writeRegistry(pid: ProcessInfo.processInfo.processIdentifier,
                          sessionId: "live-session", cwd: "/tmp/live-cwd",
                          version: "2.1.777")
        try writeRegistry(pid: deadPid, sessionId: "dead-session")

        let scans = Adapters.claudeSessionScans(projectSlug: "p",
                                                projectsDir: projectsDir,
                                                sessionsDir: sessionsDir)
        let live = try XCTUnwrap(scans.first { $0.id == "live-session" })
        let dead = try XCTUnwrap(scans.first { $0.id == "dead-session" })
        XCTAssertTrue(live.isLive)
        XCTAssertEqual(live.cwd, "/tmp/live-cwd")           // registry wins
        XCTAssertEqual(live.claudeVersion, "2.1.777")
        XCTAssertFalse(dead.isLive, "a registry record whose pid is gone is not live")
    }

    func testMalformedRegistryRecordsAreSkipped() throws {
        try writeSession(slug: "p", id: "some-session", lines: ["{}"])
        try "not json at all".write(to: sessionsDir.appendingPathComponent("123.json"),
                                    atomically: true, encoding: .utf8)
        try "[1,2,3]".write(to: sessionsDir.appendingPathComponent("456.json"),
                            atomically: true, encoding: .utf8)
        // Missing pid.
        try #"{"sessionId":"some-session"}"#.write(
            to: sessionsDir.appendingPathComponent("789.json"),
            atomically: true, encoding: .utf8)
        let scans = Adapters.claudeSessionScans(projectSlug: "p",
                                                projectsDir: projectsDir,
                                                sessionsDir: sessionsDir)
        XCTAssertEqual(scans.count, 1)
        XCTAssertFalse(scans[0].isLive)
    }

    // MARK: - Needs-attention heuristic

    func testNeedsAttentionOnlyWhenLiveAndQuiet() throws {
        let quiet = Date(timeIntervalSinceNow: -120)
        try writeSession(slug: "p", id: "live-quiet", lines: ["{}"], mtime: quiet)
        try writeSession(slug: "p", id: "live-busy", lines: ["{}"])  // fresh mtime
        try writeSession(slug: "p", id: "dead-quiet", lines: ["{}"], mtime: quiet)
        let mypid = ProcessInfo.processInfo.processIdentifier
        try writeRegistry(pid: mypid, sessionId: "live-quiet")
        // Second registry record under a different (also-alive) pid: pid 1.
        try writeRegistry(pid: 1, sessionId: "live-busy")

        let scans = Adapters.claudeSessionScans(projectSlug: "p",
                                                projectsDir: projectsDir,
                                                sessionsDir: sessionsDir,
                                                attentionIdleThreshold: 30)
        func scan(_ id: String) throws -> Adapters.ClaudeSessionScan {
            try XCTUnwrap(scans.first { $0.id == id })
        }
        XCTAssertTrue(try scan("live-quiet").needsAttention,
                      "live + quiet past the threshold = waiting on the user")
        XCTAssertFalse(try scan("live-busy").needsAttention,
                       "live + recently writing = working")
        XCTAssertFalse(try scan("dead-quiet").needsAttention,
                       "not live = nothing to attend to")
    }

    // MARK: - jsonl tail scan (last prompt / cwd / version)

    func testTailScanExtractsLastPromptCwdAndVersion() throws {
        try writeSession(slug: "p", id: "rich-session", lines: [
            #"{"type":"last-prompt","lastPrompt":"first prompt","sessionId":"rich-session"}"#,
            #"{"type":"system","cwd":"/tmp/rich","version":"2.1.221","uuid":"x"}"#,
            "THIS LINE IS NOT JSON {{{",
            #"{"type":"last-prompt","leafUuid":"no-prompt-field-here"}"#,
            #"{"type":"last-prompt","lastPrompt":"newest prompt","sessionId":"rich-session"}"#,
            #"{"type":"mode","mode":"normal"}"#,
        ])
        let scans = Adapters.claudeSessionScans(projectSlug: "p",
                                                projectsDir: projectsDir,
                                                sessionsDir: sessionsDir)
        let scan = try XCTUnwrap(scans.first)
        XCTAssertEqual(scan.lastPrompt, "newest prompt",
                       "newest last-prompt line wins; typed lines without the field are skipped")
        XCTAssertEqual(scan.cwd, "/tmp/rich")
        XCTAssertEqual(scan.claudeVersion, "2.1.221")
        XCTAssertFalse(scan.isLive)
    }

    func testTailScanSurvivesEmptyAndBinaryFiles() throws {
        try writeSession(slug: "p", id: "empty-session", lines: [])
        let dir = projectsDir.appendingPathComponent("p")
        try Data([0xff, 0xfe, 0x00, 0x01]).write(
            to: dir.appendingPathComponent("binary-session.jsonl"))
        let scans = Adapters.claudeSessionScans(projectSlug: "p",
                                                projectsDir: projectsDir,
                                                sessionsDir: sessionsDir)
        XCTAssertEqual(scans.count, 2, "unparseable content degrades, never drops the session")
        for scan in scans {
            XCTAssertNil(scan.lastPrompt)
            XCTAssertNil(scan.cwd)
        }
    }

    func testTailScanBoundsReadOnHugeFile() throws {
        // 1 MB of filler, prompt line at the END (inside the 256 KB tail) —
        // and an early prompt OUTSIDE the tail that must not be reached.
        var lines = [#"{"type":"last-prompt","lastPrompt":"unreachable early prompt"}"#]
        let filler = #"{"type":"filler","data":""# + String(repeating: "x", count: 1024) + "\"}"
        lines.append(contentsOf: Array(repeating: filler, count: 1024))
        lines.append(#"{"type":"last-prompt","lastPrompt":"tail prompt"}"#)
        let url = try writeSession(slug: "p", id: "huge-session", lines: lines)
        let result = Adapters.claudeJsonlTailScan(url)
        XCTAssertEqual(result.lastPrompt, "tail prompt")
    }

    // MARK: - MEMTERM_CLAUDE_DIR test seam (stage 3: probes point the ONE
    // parsing site at a fixture tree; the kit surface passes through)

    func testClaudeDirOverrideRedirectsBothDefaultDirs() throws {
        setenv("MEMTERM_CLAUDE_DIR", root.path, 1)
        defer { unsetenv("MEMTERM_CLAUDE_DIR") }
        XCTAssertEqual(Adapters.defaultClaudeProjectsDir.path, projectsDir.path)
        XCTAssertEqual(Adapters.defaultClaudeSessionsDir.path, sessionsDir.path)
        // The default-argument scan surfaces (what the app's Host wiring
        // calls) now read the fixture world.
        try writeSession(slug: "seam-proj", id: "dddd-4444", lines: ["{}"])
        let scans = Adapters.claudeProjectScans()
        XCTAssertEqual(scans.map(\.slug), ["seam-proj"])
        XCTAssertEqual(Adapters.claudeSessionScans(projectSlug: "seam-proj").map(\.id),
                       ["dddd-4444"])
    }

    func testClaudeDirOverrideEmptyOrUnsetFallsBackToHome() {
        unsetenv("MEMTERM_CLAUDE_DIR")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(Adapters.defaultClaudeProjectsDir.path.hasPrefix(home))
        setenv("MEMTERM_CLAUDE_DIR", "", 1)
        defer { unsetenv("MEMTERM_CLAUDE_DIR") }
        XCTAssertTrue(Adapters.defaultClaudeSessionsDir.path.hasPrefix(home),
                      "empty override is no override")
    }

    // MARK: - Read-only smoke against the REAL ~/.claude (founder rule:
    // reading is allowed for real-data verification; NOTHING here writes)

    func testRealClaudeDirParsesWithoutError() throws {
        let real = Adapters.defaultClaudeProjectsDir
        try XCTSkipUnless(FileManager.default.fileExists(atPath: real.path),
                          "no real ~/.claude/projects on this machine")
        let projects = Adapters.claudeProjectScans()
        XCTAssertFalse(projects.isEmpty, "real projects dir lists at least one project")
        let totalSessions = projects.reduce(0) { $0 + $1.sessionCount }
        XCTAssertGreaterThan(totalSessions, 0, "real projects dir holds sessions")
        // Scan the most recently active project end-to-end: must not crash,
        // ids must be valid, ordering newest-first.
        let sessions = Adapters.claudeSessionScans(projectSlug: projects[0].slug)
        for session in sessions {
            XCTAssertTrue(Adapters.isValidClaudeSessionId(session.id))
        }
        for pair in zip(sessions, sessions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.lastActivity, pair.1.lastActivity)
        }
    }
}
