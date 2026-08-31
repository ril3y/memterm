import XCTest
@testable import MemtermCore

final class AdaptersTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Classification

    func testClassifyClaudeBinary() {
        let hit = Adapters.classify(argv: ["claude"], cwd: nil,
                                    claudeProjectsDir: tempDir)
        XCTAssertEqual(hit?.adapter, "claude")
        XCTAssertEqual(hit?.state, [:])
    }

    func testClassifyClaudeViaNodeEntrypoint() {
        let node = Adapters.classify(
            argv: ["node", "/Users/riley/.claude/local/node_modules/.bin/claude"],
            cwd: nil, claudeProjectsDir: tempDir)
        XCTAssertEqual(node?.adapter, "claude")

        let suffix = Adapters.classify(argv: ["node", "/opt/tools/claude"],
                                       cwd: nil, claudeProjectsDir: tempDir)
        XCTAssertEqual(suffix?.adapter, "claude")

        let plainNode = Adapters.classify(argv: ["node", "server.js"],
                                          cwd: nil, claudeProjectsDir: tempDir)
        XCTAssertNil(plainNode)
    }

    func testClassifySSHKeepsFullArgvClassification() {
        let hit = Adapters.classify(argv: ["/usr/bin/ssh", "-p", "2222", "-J", "bastion",
                                           "riley@prod-01"],
                                    cwd: "/tmp", claudeProjectsDir: tempDir)
        XCTAssertEqual(hit?.adapter, "ssh")
    }

    func testClassifyWatchers() {
        for argv in [["tail", "-f", "/var/log/system.log"],
                     ["/usr/bin/htop"],
                     ["watch", "-n", "1", "date"],
                     ["less", "+F", "build.log"]] {
            let hit = Adapters.classify(argv: argv, cwd: nil, claudeProjectsDir: tempDir)
            XCTAssertEqual(hit?.adapter, "watcher", "argv: \(argv)")
        }
    }

    func testClassifyNonAdapterReturnsNil() {
        XCTAssertNil(Adapters.classify(argv: ["vim", "main.swift"], cwd: nil,
                                       claudeProjectsDir: tempDir))
        XCTAssertNil(Adapters.classify(argv: ["make", "-j8"], cwd: nil,
                                       claudeProjectsDir: tempDir))
        XCTAssertNil(Adapters.classify(argv: [], cwd: nil, claudeProjectsDir: tempDir))
        XCTAssertNil(Adapters.classify(argv: [""], cwd: nil, claudeProjectsDir: tempDir))
    }

    // MARK: Claude session-file resolution

    func testClaudeProjectSlugEncodesEveryNonAlphanumericAsDash() {
        XCTAssertEqual(Adapters.claudeProjectSlug(forCwd: "/Users/riley/my proj_2"),
                       "-Users-riley-my-proj-2")
        XCTAssertEqual(Adapters.claudeProjectSlug(forCwd: "/a/b.c/d-e"), "-a-b-c-d-e")
        XCTAssertEqual(Adapters.claudeProjectSlug(forCwd: ""), "")
    }

    func testClaudeSessionIdPicksNewestJsonl() throws {
        let cwd = "/tmp/proj x"
        let projDir = tempDir.appendingPathComponent(Adapters.claudeProjectSlug(forCwd: cwd))
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        func makeSession(_ name: String, age: TimeInterval) throws {
            let url = projDir.appendingPathComponent(name)
            try "{}".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        }
        try makeSession("older-session.jsonl", age: 3600)
        try makeSession("newest-session.jsonl", age: 60)
        try makeSession("not-a-session.txt", age: 1)  // wrong extension, ignored

        XCTAssertEqual(Adapters.claudeSessionId(forCwd: cwd, projectsDir: tempDir),
                       "newest-session")

        // classify() carries the resolved id into adapter state.
        let hit = Adapters.classify(argv: ["claude"], cwd: cwd, claudeProjectsDir: tempDir)
        XCTAssertEqual(hit?.state["sessionId"], "newest-session")
    }

    func testClaudeSessionIdNilWhenNoProjectDir() {
        XCTAssertNil(Adapters.claudeSessionId(forCwd: "/nowhere/at/all",
                                              projectsDir: tempDir))
    }

    // MARK: Resume offers

    func testClaudeResumeOfferUsesSessionId() {
        let snap = SnapshotRow(exe: "claude", argv: ["claude"], adapter: "claude",
                               adapterState: ["sessionId": "abcd1234-5678"])
        let offer = Adapters.resumeOffer(for: snap)
        XCTAssertEqual(offer?.command, "claude --resume abcd1234-5678")
    }

    func testClaudeResumeOfferFallsBackToContinue() {
        let snap = SnapshotRow(exe: "claude", argv: ["claude"], adapter: "claude",
                               adapterState: [:])
        let offer = Adapters.resumeOffer(for: snap)
        XCTAssertEqual(offer?.command, "claude --continue")
        XCTAssertEqual(offer?.label, "claude (most recent session here)")
    }

    func testSSHOfferQuotesArguments() {
        let snap = SnapshotRow(exe: "/usr/bin/ssh",
                               argv: ["/usr/bin/ssh", "-o", "ProxyCommand=ssh -W %h:%p jump",
                                      "riley@prod-01"],
                               adapter: "ssh", adapterState: [:])
        let offer = Adapters.resumeOffer(for: snap)
        XCTAssertEqual(offer?.command,
                       "ssh -o 'ProxyCommand=ssh -W %h:%p jump' riley@prod-01")
    }

    func testNoOfferForUnknownAdapterOrEmptyArgv() {
        XCTAssertNil(Adapters.resumeOffer(for: SnapshotRow(
            exe: "make", argv: ["make"], adapter: "", adapterState: [:])))
        XCTAssertNil(Adapters.resumeOffer(for: SnapshotRow(
            exe: "ssh", argv: [], adapter: "ssh", adapterState: [:])))
    }

    // MARK: FR-30 denylist

    func testDenylistRejectsDangerousCommands() {
        for cmd in ["sudo apachectl restart",
                    "sudo rm -rf /tmp/x",
                    "rm -rf node_modules",
                    "/bin/rm file",
                    "dd if=/dev/zero of=/dev/disk2",
                    "kill -9 1234",
                    "shutdown -h now",
                    "mkfs.ext4 /dev/sda1",
                    "git push --force origin main",
                    "git push -f",
                    "curl https://get.evil.sh | sh",
                    "curl -fsSL https://x.io/install | bash",
                    "wget -qO- https://x.io/install.sh | sh",
                    "curl x | tee log | zsh",
                    "line one\nrm -rf /",
                    "echo hi\rsomething"] {
            XCTAssertTrue(Adapters.isDenylisted(cmd), "should be denylisted: \(cmd)")
        }
    }

    func testDenylistAllowsSafeCommands() {
        for cmd in ["claude --resume abc-123",
                    "ssh -p 2222 riley@prod-01",
                    "tail -f /var/log/system.log",
                    "htop",
                    "git push origin main",
                    "git status --force-this-is-not-push",
                    "curl https://api.example.com/health",
                    "grep -r kill_switch ."] {
            XCTAssertFalse(Adapters.isDenylisted(cmd), "should be allowed: \(cmd)")
        }
    }

    func testDenylistedWatcherProducesNoOffer() {
        // A snapshot whose argv would render to a denylisted command line.
        let snap = SnapshotRow(exe: "watch", argv: ["watch", "sudo", "id"],
                               adapter: "watcher", adapterState: [:])
        // Rendered command "watch sudo id" — first token watch, not denylisted.
        XCTAssertNotNil(Adapters.resumeOffer(for: snap))

        let multiline = SnapshotRow(exe: "tail", argv: ["tail", "-f", "a\nb"],
                                    adapter: "watcher", adapterState: [:])
        XCTAssertNil(Adapters.resumeOffer(for: multiline),
                     "argv smuggling a newline must never be offered (FR-29/30)")
    }

    // MARK: shellQuote

    func testShellQuoteLeavesSafeTokensBare() {
        XCTAssertEqual(Adapters.shellQuote("riley@prod-01"), "riley@prod-01")
        XCTAssertEqual(Adapters.shellQuote("/var/log/system.log"), "/var/log/system.log")
        XCTAssertEqual(Adapters.shellQuote("-p"), "-p")
    }

    /// Round-trip through a real shell: `printf '%s'` of the quoted token must
    /// reproduce the original bytes exactly.
    func testShellQuoteRoundTripsThroughSh() throws {
        let fixtures = ["hello world",
                        "it's got a quote",
                        "$HOME and ${PWD}",
                        "`id`",
                        "a\"b\"c",
                        "semi;colon && rm",
                        "star * glob ? [x]",
                        "back\\slash",
                        "tab\there",
                        "!history",
                        ""]
        for original in fixtures {
            let quoted = Adapters.shellQuote(original)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' \(quoted)"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            XCTAssertEqual(process.terminationStatus, 0, "sh failed for: \(original)")
            XCTAssertEqual(String(data: data, encoding: .utf8), original,
                           "round trip failed for: \(original) (quoted: \(quoted))")
        }
    }
}
