import XCTest
@testable import MemtermCore

// End-to-end verification of the ZDOTDIR wrapper against REAL /bin/zsh,
// headlessly: a temp HOME + temp state dir, interactive login shells fed via
// piped stdin (preexec/precmd fire for those — empirically established
// before this design was wired in). Covers:
//   (a) the user's rc executes (marker env var),
//   (b) preexec appends commands to the pane's .hist file,
//   (c) a second shell with the same MEMTERM_PANE_ID sees them via fc -l,
//       seeded NEWEST (after global history),
//   (d) a shell without integration files / without MEMTERM vars still works,
//   (e) an oh-my-zsh-style rc with its own precmd()/preexec() coexists,
//   (f) startup overhead stays under the 50 ms budget.

final class ShellIntegrationZshTests: XCTestCase {

    private var root: URL!
    private var home: URL!
    private var integrationDir: URL!
    private var histDir: URL!
    private let zshPath = "/bin/zsh"

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: zshPath),
                          "no /bin/zsh on this machine")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-zsh-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        integrationDir = root.appendingPathComponent("shell-integration")
        histDir = root.appendingPathComponent("history")
        for dir in [home, histDir] {
            try FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        }
        XCTAssertTrue(ShellIntegration.install(into: integrationDir))
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ name: String, _ content: String) throws {
        try content.write(to: home.appendingPathComponent(name), atomically: true,
                          encoding: .utf8)
    }

    /// Runs an interactive login zsh (the way memterm spawns panes) with the
    /// wrapper env, feeding `input` on stdin. Returns combined stdout+stderr.
    @discardableResult
    private func runZsh(input: String, paneId: String? = "PANE-TEST",
                        zdotdir: String? = nil, timeout: TimeInterval = 15) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: zshPath)
        process.arguments = ["-l", "-i"]
        var env: [String: String] = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "SHELL": zshPath,
            // Real panes inherit the login locale; without one, zsh on the
            // CI runners (macos-15) prints multibyte history entries
            // meta-escaped and the unicode-entry assertion fails there.
            "LANG": "en_US.UTF-8",
        ]
        env["ZDOTDIR"] = zdotdir ?? integrationDir.path
        if let paneId {
            env["MEMTERM_PANE_ID"] = paneId
            env["MEMTERM_HIST_DIR"] = histDir.path
        }
        process.environment = env
        let stdin = Pipe(), out = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = out
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        stdin.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("zsh did not exit within \(timeout)s")
        }
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func histFile(_ paneId: String = "PANE-TEST") -> URL {
        ShellIntegration.histFileURL(dir: histDir, paneId: paneId)
    }

    // MARK: (a) user rc executes through the wrapper

    func testUserRcRunsWithMarkerAndZdotdirRestored() throws {
        try write(".zshenv", "export T_ZSHENV=1\n")
        try write(".zprofile", "export T_ZPROFILE=1\n")
        try write(".zshrc", "export T_ZSHRC=1\n")
        try write(".zlogin", "export T_ZLOGIN=1\n")
        let out = try runZsh(input: "echo \"MARK env=$T_ZSHENV,$T_ZPROFILE,$T_ZSHRC,$T_ZLOGIN zdot=<$ZDOTDIR>\"\nexit\n")
        XCTAssertTrue(out.contains("MARK env=1,1,1,1 zdot=<>"),
                      "user startup files did not all run / ZDOTDIR not restored: \(out)")
    }

    // MARK: (b) preexec appends to the pane's .hist

    func testCommandsLandInPaneHistFile() throws {
        try write(".zshrc", "HISTFILE=$HOME/.zsh_history\nHISTSIZE=1000\nSAVEHIST=1000\n")
        try runZsh(input: ": memterm-test-cmd-alpha\necho ran\nexit\n")
        let hist = try String(contentsOf: histFile(), encoding: .utf8)
        XCTAssertTrue(hist.contains(":0;: memterm-test-cmd-alpha"), "hist: \(hist)")
        XCTAssertTrue(hist.contains(":0;echo ran"), "hist: \(hist)")
        // Extended-history shape on every line.
        for line in hist.split(separator: "\n") {
            XCTAssertNotNil(line.range(of: #"^: \d+:0;"#, options: .regularExpression),
                            "malformed hist line: \(line)")
        }
        // 0600: the file is created by the shell, perms must still be tight.
        let perms = try FileManager.default.attributesOfItem(atPath: histFile().path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: (c) a second shell with the same pane id seeds it — newest

    func testSecondShellSeesPaneHistorySeededNewest() throws {
        try write(".zshrc", "HISTFILE=$HOME/.zsh_history\nHISTSIZE=1000\nSAVEHIST=1000\n")
        try write(".zsh_history", ": 1600000000:0;global-old-command\n")
        // Shell 1 records a command for this pane.
        try runZsh(input: ": pane-cmd-from-shell-one\nexit\n")
        // Shell 2, same pane id: fc -l must show the pane command, and it
        // must be NEWER than the global entry (↑ walks the tab's own
        // commands first).
        let out = try runZsh(input: "fc -l 1\nexit\n")
        guard let globalPos = out.range(of: "global-old-command"),
              let panePos = out.range(of: "pane-cmd-from-shell-one") else {
            return XCTFail("fc -l missing entries: \(out)")
        }
        XCTAssertTrue(globalPos.lowerBound < panePos.lowerBound,
                      "pane history must seed AFTER (newer than) global history: \(out)")
    }

    // MARK: (d) degradation — no integration files / not a memterm pane

    func testShellWorksWithoutIntegrationFiles() throws {
        try write(".zshrc", "export T_ZSHRC=1\n")
        // ZDOTDIR at a dir with no files at all: zsh loads nothing, works.
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let out = try runZsh(input: "echo DEGRADED-OK\nexit\n", zdotdir: empty.path)
        XCTAssertTrue(out.contains("DEGRADED-OK"), out)
    }

    func testIntegrationFilesWithoutMemtermVarsAreInert() throws {
        try write(".zshrc", "export T_ZSHRC=1\n")
        let out = try runZsh(input: "echo INERT-$T_ZSHRC\nexit\n", paneId: nil)
        XCTAssertTrue(out.contains("INERT-1"), out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: histFile().path),
                       "no pane id → no hist file")
    }

    func testBrokenUserRcDoesNotKillShellOrHooks() throws {
        try write(".zshrc", "this-command-does-not-exist-xyz\nsyntax error (((\n")
        let out = try runZsh(input: ": after-broken-rc\necho STILL-ALIVE\nexit\n")
        XCTAssertTrue(out.contains("STILL-ALIVE"), out)
        // Hooks installed AFTER the broken rc still captured the command.
        let hist = try String(contentsOf: histFile(), encoding: .utf8)
        XCTAssertTrue(hist.contains("after-broken-rc"), "hist: \(hist)")
    }

    // MARK: (e) oh-my-zsh / powerlevel10k-style coexistence

    func testOmzStyleRcWithOwnHooksCoexists() throws {
        try write(".zshrc", """
        # fake omz-style rc: own precmd/preexec functions, hook array use,
        # powerline-ish prompt.
        HISTFILE=$HOME/.zsh_history
        HISTSIZE=1000
        SAVEHIST=1000
        autoload -Uz add-zsh-hook
        autoload -Uz compinit && compinit -u -d "$HOME/.zcompdump"
        PROMPT='%F{blue}%n@%m%f %F{green}%~%f ❯ '
        precmd() { print -u2 "USER-PRECMD-RAN" }
        preexec() { print -u2 "USER-PREEXEC-RAN:$1" }
        _user_array_hook() { print -u2 "USER-ARRAY-HOOK-RAN" }
        add-zsh-hook precmd _user_array_hook
        """)
        let out = try runZsh(input: ": coexist-cmd\nexit\n")
        XCTAssertTrue(out.contains("USER-PRECMD-RAN"), "user precmd() lost: \(out)")
        XCTAssertTrue(out.contains("USER-PREEXEC-RAN:: coexist-cmd"), "user preexec() lost: \(out)")
        XCTAssertTrue(out.contains("USER-ARRAY-HOOK-RAN"), "user hook-array entry lost: \(out)")
        let hist = try String(contentsOf: histFile(), encoding: .utf8)
        XCTAssertTrue(hist.contains("coexist-cmd"), "memterm hook lost: \(hist)")
        // FR-5 bonus marks still emitted under the omz-style setup.
        XCTAssertTrue(out.contains("\u{1b}]133;A"), "OSC 133 A missing")
        XCTAssertTrue(out.contains("\u{1b}]133;C"), "OSC 133 C missing")
        XCTAssertTrue(out.contains("\u{1b}]7;file://"), "OSC 7 missing")
    }

    // MARK: /etc/zshrc HISTFILE hijack repair (wrapper v2)

    /// Whether this machine's /etc/zshrc applies the stock macOS default
    /// (HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history) that the wrapper must undo.
    private var etcZshrcSetsHistfile: Bool {
        (try? String(contentsOf: URL(fileURLWithPath: "/etc/zshrc"),
                     encoding: .utf8))?.contains("HISTFILE=${ZDOTDIR") ?? false
    }

    func testGlobalHistfileNotHijackedIntoIntegrationDir() throws {
        try XCTSkipUnless(etcZshrcSetsHistfile, "/etc/zshrc has no ZDOTDIR HISTFILE default")
        // No user rc files at all — the default macOS setup, where HISTFILE
        // comes solely from /etc/zshrc. (Also hostile-rc matrix case (d):
        // shell must come up with no rc files, hooks alive.)
        let out = try runZsh(input: ": no-rc-cmd\necho \"HF=<$HISTFILE>\"\nexit\n")
        XCTAssertTrue(out.contains("HF=<\(home.path)/.zsh_history>"),
                      "HISTFILE not repaired to the user's own: \(out)")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: integrationDir.appendingPathComponent(".zsh_history").path),
            "global history leaked into the integration dir")
        // Hooks alive with no rc files: the command landed in the pane file.
        let hist = try String(contentsOf: histFile(), encoding: .utf8)
        XCTAssertTrue(hist.contains("no-rc-cmd"), "hist: \(hist)")
        // ...and the user's real global history file gained the session.
        let global = (try? String(contentsOf: home.appendingPathComponent(".zsh_history"),
                                  encoding: .utf8)) ?? ""
        XCTAssertTrue(global.contains("no-rc-cmd"),
                      "session not saved to the user's global history: \(global)")
    }

    func testOmzConditionalHistfileGetsRepairedValue() throws {
        try XCTSkipUnless(etcZshrcSetsHistfile, "/etc/zshrc has no ZDOTDIR HISTFILE default")
        // The founder shape: oh-my-zsh sets HISTFILE only when it is UNSET —
        // /etc/zshrc's ZDOTDIR-based value used to survive that and hijack
        // global history into the state dir.
        try write(".zshrc", "[[ -z \"$HISTFILE\" ]] && HISTFILE=\"$HOME/.zsh_history\"\n")
        let out = try runZsh(input: "echo \"HF=<$HISTFILE>\"\nexit\n")
        XCTAssertTrue(out.contains("HF=<\(home.path)/.zsh_history>"),
                      "omz-conditional setup still hijacked: \(out)")
    }

    func testUserSetHistfileWinsOverRepair() throws {
        try write(".zshrc", "HISTFILE=$HOME/.custom_history\nHISTSIZE=50\nSAVEHIST=50\n")
        let out = try runZsh(input: "echo \"HF=<$HISTFILE>\"\nexit\n")
        XCTAssertTrue(out.contains("HF=<\(home.path)/.custom_history>"),
                      "user's explicit HISTFILE was not honored: \(out)")
    }

    // MARK: seed-time injection safety (fc -R only LOADS, never runs)

    func testMaliciousHistoryLinesNeverExecuteAtSeedTime() throws {
        try write(".zshrc", "HISTFILE=$HOME/.zsh_history\nHISTSIZE=1000\nSAVEHIST=1000\n")
        let bomb = home.appendingPathComponent("EXPLODED").path
        // Hostile pane file, as an attacker with state-dir access could leave
        // it: command substitution, backticks, quotes, %, unicode, a line
        // that is not even extended-history shaped.
        let hostile = """
        : 1700000000:0;touch \(bomb)-plain
        : 1700000001:0;$(touch \(bomb)-subst)
        : 1700000002:0;`touch \(bomb)-tick`
        : 1700000003:0;echo "100%" 'q' ünïcode-漢字
        touch \(bomb)-bare
        """
        try (hostile + "\n").write(to: histFile(), atomically: true, encoding: .utf8)
        let out = try runZsh(input: "echo SEED-ALIVE\nfc -l 1\nexit\n")
        XCTAssertTrue(out.contains("SEED-ALIVE"), "shell died seeding hostile file: \(out)")
        for suffix in ["-plain", "-subst", "-tick", "-bare"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: bomb + suffix),
                           "fc -R EXECUTED a history line (\(suffix))")
        }
        // The entries are recallable text (that is the feature)...
        XCTAssertTrue(out.contains("ünïcode-漢字"), "unicode entry lost: \(out)")
        // ...and the file itself was not corrupted by the seed.
        let after = try String(contentsOf: histFile(), encoding: .utf8)
        XCTAssertTrue(after.hasPrefix(": 1700000000:0;touch"), "pane file corrupted: \(after)")
    }

    func testTypedSpecialCharactersRoundTripThroughPreexec() throws {
        try write(".zshrc", "HISTFILE=$HOME/.zsh_history\nHISTSIZE=1000\nSAVEHIST=1000\n")
        // Typed via the REAL preexec path: quoting keeps the payloads inert
        // in shell 1; the recorded line must carry them verbatim, one line
        // per command, including a multi-line command flattened.
        let cmd = ": 'q1' \"q2\" '$(not-run)' '`not-run`' '100%' 'ünïcode-漢字'"
        try runZsh(input: cmd + "\necho 'l1\nl2'\nexit\n")
        let hist = try String(contentsOf: histFile(), encoding: .utf8)
        XCTAssertTrue(hist.contains(";\(cmd)"), "special chars mangled: \(hist)")
        XCTAssertTrue(hist.contains(";echo 'l1 l2'"), "newline not flattened: \(hist)")
        for line in hist.split(separator: "\n") {
            XCTAssertNotNil(line.range(of: #"^: \d+:0;"#, options: .regularExpression),
                            "malformed line: \(line)")
        }
    }

    // MARK: start-of-shell trim

    func testOversizedHistFileIsTrimmedAtShellStart() throws {
        try write(".zshrc", "")
        var big = ""
        for i in 0..<2500 { big += ": 1700000000:0;cmd-\(i)\n" }
        try big.write(to: histFile(), atomically: true, encoding: .utf8)
        try runZsh(input: "exit\n")
        let lines = try String(contentsOf: histFile(), encoding: .utf8)
            .split(separator: "\n")
        // 1000 kept + the 'exit' just typed.
        XCTAssertEqual(lines.count, 1001, "trim did not run")
        XCTAssertTrue(lines.first!.contains("cmd-1500"), "wrong lines kept: \(lines.first!)")
        // v3 freeze-before-trim (amended FR-56): the 1500 head lines ROLLED
        // into the sidecar instead of being discarded — real zsh, real roll.
        let sidecar = URL(fileURLWithPath: histFile().path + ".trimmed")
        let rolled = try String(contentsOf: sidecar, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(rolled.count, 1500, "trimmed lines must roll, not vanish")
        XCTAssertTrue(rolled.first!.contains("cmd-0"), "sidecar wrong head: \(rolled.first!)")
        XCTAssertTrue(rolled.last!.contains("cmd-1499"), "sidecar wrong tail: \(rolled.last!)")
        let perms = try XCTUnwrap(try FileManager.default.attributesOfItem(
            atPath: sidecar.path)[.posixPermissions] as? Int)
        XCTAssertEqual(perms & 0o777, 0o600, "sidecar must be 0600 (NFR-10)")
        // A SECOND oversize start appends to the same sidecar (>>|), never
        // truncates what an earlier roll saved.
        var again = ""
        for i in 2500..<5100 { again += ": 1700000000:0;cmd-\(i)\n" }
        try again.write(to: histFile(), atomically: true, encoding: .utf8)
        try runZsh(input: "exit\n")
        let rolled2 = try String(contentsOf: sidecar, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(rolled2.count, 1500 + 1600, "second roll must append")
        XCTAssertTrue(rolled2.first!.contains("cmd-0"))
    }

    // MARK: (f) startup overhead < 50 ms

    func testStartupOverheadUnderBudget() throws {
        try write(".zshrc", "HISTFILE=$HOME/.zsh_history\nHISTSIZE=1000\nSAVEHIST=1000\n")
        func medianStartup(zdotdir: String?, paneId: String?) throws -> TimeInterval {
            var samples: [TimeInterval] = []
            for _ in 0..<5 {
                let t0 = Date()
                try runZsh(input: "exit\n", paneId: paneId, zdotdir: zdotdir)
                samples.append(Date().timeIntervalSince(t0))
            }
            return samples.sorted()[samples.count / 2]
        }
        _ = try medianStartup(zdotdir: home.path, paneId: nil)  // warm caches
        let bare = try medianStartup(zdotdir: home.path, paneId: nil)
        let wrapped = try medianStartup(zdotdir: nil, paneId: "PANE-TIMING")
        let delta = wrapped - bare
        print("shell-integration startup overhead: bare=\(Int(bare * 1000))ms wrapped=\(Int(wrapped * 1000))ms delta=\(Int(delta * 1000))ms")
        XCTAssertLessThan(delta, 0.050,
                          "integration adds \(Int(delta * 1000))ms (budget 50ms)")
    }
}
