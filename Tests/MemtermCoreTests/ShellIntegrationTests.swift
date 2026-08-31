import XCTest
@testable import MemtermCore

// Pure pieces of the zsh shell integration (per-tab ↑ history): history-line
// formatting/escaping, cap-trim logic, hist filename containment, environment
// composition, and generated-file invariants. The real-zsh end-to-end checks
// live in ShellIntegrationZshTests.

final class ShellIntegrationTests: XCTestCase {

    // MARK: - History-line formatting

    func testFormatsExtendedHistoryLine() {
        XCTAssertEqual(ShellIntegration.formatHistoryLine(epoch: 1700000000,
                                                          command: "ping google.com"),
                       ": 1700000000:0;ping google.com")
    }

    func testQuotesAndPercentSignsPassThroughVerbatim() {
        let cmd = #"echo "100%" 'single' $VAR %{weird%}"#
        XCTAssertEqual(ShellIntegration.formatHistoryLine(epoch: 1, command: cmd),
                       ": 1:0;\(cmd)")
    }

    func testNewlinesAreFlattenedToOneLine() {
        let cmd = "echo one\necho two\r\necho three\rend"
        let line = ShellIntegration.formatHistoryLine(epoch: 5, command: cmd)
        XCTAssertEqual(line, ": 5:0;echo one echo two echo three end")
        XCTAssertFalse(line!.contains("\n"))
        XCTAssertFalse(line!.contains("\r"))
    }

    func testEmptyAndWhitespaceCommandsProduceNoLine() {
        XCTAssertNil(ShellIntegration.formatHistoryLine(epoch: 1, command: ""))
        XCTAssertNil(ShellIntegration.formatHistoryLine(epoch: 1, command: "  \n \r "))
    }

    // MARK: - Cap trim

    func testTrimKeepsFilesUnderThresholdIntact() {
        let lines = (0..<2000).map { ": 1:0;cmd-\($0)" }
        XCTAssertEqual(ShellIntegration.trimmedHistory(lines: lines).count, 2000)
    }

    func testTrimRewritesToLastKeepLinesOverThreshold() {
        let lines = (0..<2500).map { ": 1:0;cmd-\($0)" }
        let trimmed = ShellIntegration.trimmedHistory(lines: lines)
        XCTAssertEqual(trimmed.count, 1000)
        XCTAssertEqual(trimmed.first, ": 1:0;cmd-1500")
        XCTAssertEqual(trimmed.last, ": 1:0;cmd-2499")
    }

    // MARK: - Filename containment (same rule as scrollback files)

    func testHistFileNameContainsTraversalAttempts() {
        let dir = URL(fileURLWithPath: "/state/history", isDirectory: true)
        for hostile in ["../../etc/passwd", "/absolute/path", "a/b", "..", ""] {
            let url = ShellIntegration.histFileURL(dir: dir, paneId: hostile)
            XCTAssertEqual(url.deletingLastPathComponent().path, "/state/history",
                           "id \(hostile) escaped the history dir: \(url.path)")
            XCTAssertFalse(url.lastPathComponent.contains("/"))
            XCTAssertFalse(url.lastPathComponent.contains(".."))
        }
        // A normal UUID id round-trips recognizably.
        let uuid = "A1B2C3D4-0000-4444-8888-ABCDEF012345"
        XCTAssertEqual(ShellIntegration.histFileURL(dir: dir, paneId: uuid).lastPathComponent,
                       "\(uuid).hist")
    }

    func testSwiftAndZshSanitizationAgreeForAllIds() {
        // The .zshrc hook sanitizes with ${MEMTERM_PANE_ID//[^A-Za-z0-9-]/_}
        // (ASCII only); histSafePaneId must agree for EVERY id, not just the
        // UUIDs memterm generates — pane ids round-trip through the
        // user-editable journal/JSON, and the shell writes the file that the
        // forget flows must later delete. Unicode alphanumerics in particular
        // must map to '_' (ScrollbackText.safePaneId keeps them, zsh doesn't).
        for id in ["ABC-123", UUID().uuidString, "weird id!", "p\u{00E9}x",
                   "\u{6F22}\u{5B57}", "e\u{0301}mixed", "..", "a/b"] {
            let zshStyle = String(id.unicodeScalars.map { s -> Character in
                let v = s.value
                let ok = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                      || (v >= 0x30 && v <= 0x39) || v == 0x2D
                return ok ? Character(s) : "_"
            })
            XCTAssertEqual(ShellIntegration.histSafePaneId(id), zshStyle, "id: \(id)")
        }
        // For the ids memterm actually generates, both sanitizers agree, so
        // .txt and .hist files share a stem.
        let uuid = UUID().uuidString
        XCTAssertEqual(ShellIntegration.histSafePaneId(uuid), ScrollbackText.safePaneId(uuid))
    }

    // MARK: - Environment composition

    func testEnvironmentAddsIntegrationVariablesToBase() {
        let env = ShellIntegration.environment(base: ["TERM=xterm-256color", "HOME=/Users/x"],
                                               paneId: "P1", histDir: "/s/history",
                                               userZdotdir: "/Users/x",
                                               integrationDir: "/s/shell-integration")
        XCTAssertTrue(env.contains("TERM=xterm-256color"))
        XCTAssertTrue(env.contains("HOME=/Users/x"))
        XCTAssertTrue(env.contains("MEMTERM_PANE_ID=P1"))
        XCTAssertTrue(env.contains("MEMTERM_HIST_DIR=/s/history"))
        XCTAssertTrue(env.contains("MEMTERM_USER_ZDOTDIR=/Users/x"))
        XCTAssertTrue(env.contains("ZDOTDIR=/s/shell-integration"))
    }

    func testEnvironmentReplacesStaleIntegrationVariables() {
        let env = ShellIntegration.environment(base: ["ZDOTDIR=/old", "MEMTERM_PANE_ID=old"],
                                               paneId: "new", histDir: "/h",
                                               userZdotdir: "/u", integrationDir: "/i")
        XCTAssertFalse(env.contains("ZDOTDIR=/old"))
        XCTAssertFalse(env.contains("MEMTERM_PANE_ID=old"))
        XCTAssertTrue(env.contains("ZDOTDIR=/i"))
        XCTAssertTrue(env.contains("MEMTERM_PANE_ID=new"))
    }

    // MARK: - Generated files

    func testGeneratedFilesAreVersionStampedAndInstall() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memterm-si-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ShellIntegration.install(into: dir))
        for name in [".zshenv", ".zprofile", ".zshrc"] {
            let url = dir.appendingPathComponent(name)
            let content = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(content.contains("memterm shell integration v\(ShellIntegration.version)"),
                          "\(name) is not version-stamped")
            let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            XCTAssertEqual(perms, 0o600, "\(name) permissions")
        }
        let dirPerms = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
        // The wrapper must repair the /etc/zshrc HISTFILE hijack before the
        // user's rc runs (v2) — losing this line silently redirects the
        // user's global history into the state dir.
        XCTAssertTrue(ShellIntegration.zshrcContent
            .contains(#"[[ "${HISTFILE:-}" == "$ZDOTDIR/.zsh_history" ]]"#))
        // ...and a re-install sweeps the stray v1 hijack artifact.
        let stray = dir.appendingPathComponent(".zsh_history")
        try "polluted".write(to: stray, atomically: true, encoding: .utf8)
        XCTAssertTrue(ShellIntegration.install(into: dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path),
                       "v1 hijacked .zsh_history not cleaned up by install")
        // The trim constants must be baked into the rc verbatim.
        XCTAssertTrue(ShellIntegration.zshrcContent.contains("> \(ShellIntegration.trimThreshold)"))
        XCTAssertTrue(ShellIntegration.zshrcContent.contains("tail -n \(ShellIntegration.trimKeep)"))
    }

    func testIsZsh() {
        XCTAssertTrue(ShellIntegration.isZsh(shellPath: "/bin/zsh"))
        XCTAssertTrue(ShellIntegration.isZsh(shellPath: "/opt/homebrew/bin/zsh"))
        XCTAssertFalse(ShellIntegration.isZsh(shellPath: "/bin/bash"))
        XCTAssertFalse(ShellIntegration.isZsh(shellPath: "/usr/local/bin/fish"))
    }
}
