import Foundation

// Compiled-in adapter classification (§8, v0 of FR-34/35/37/38): what was
// running in a pane, and the exact command that would bring it back. Offers
// are consent-gated (FR-29) — memterm NEVER auto-executes a captured command,
// and there is no setting to change that.

public enum Adapters {

    public static let watcherNames: Set<String> = ["tail", "less", "more", "man", "htop", "top", "watch"]

    public static var defaultClaudeProjectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Classifies a foreground process; returns (adapter, adapter_state) or nil.
    public static func classify(argv: [String], cwd: String?,
                                claudeProjectsDir: URL = defaultClaudeProjectsDir)
        -> (adapter: String, state: [String: String])? {
        guard let first = argv.first, !first.isEmpty else { return nil }
        let base = (first as NSString).lastPathComponent

        if base == "claude" || (base == "node" && argv.contains { $0.hasSuffix("/claude") || $0.contains("/.claude/") }) {
            var state: [String: String] = [:]
            if let cwd, let sessionId = claudeSessionId(forCwd: cwd, projectsDir: claudeProjectsDir) {
                state["sessionId"] = sessionId
            }
            return ("claude", state)
        }
        if base == "ssh" {
            return ("ssh", [:])
        }
        if watcherNames.contains(base) {
            return ("watcher", [:])
        }
        return nil
    }

    /// Claude's projects-dir slug for a cwd: every non-alphanumeric character
    /// becomes '-'. Always map cwd → dir, never invert (§8).
    public static func claudeProjectSlug(forCwd cwd: String) -> String {
        var encoded = ""
        for scalar in cwd.unicodeScalars {
            encoded.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : "-")
        }
        return encoded
    }

    /// Most-recently-modified session jsonl under <projectsDir>/<encoded-cwd>/.
    public static func claudeSessionId(forCwd cwd: String,
                                       projectsDir: URL = defaultClaudeProjectsDir) -> String? {
        let dir = projectsDir.appendingPathComponent(claudeProjectSlug(forCwd: cwd))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let newest = files
            .filter { $0.pathExtension == "jsonl" }
            .max { mtime($0) < mtime($1) }
        return newest.map { $0.deletingPathExtension().lastPathComponent }
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// Claude session ids come from jsonl filenames (or persisted adapter
    /// state), so before one is interpolated into a command it must look like
    /// a session id — anything with shell metacharacters, spaces, or slashes
    /// falls back to `claude --continue` instead.
    public static func isValidClaudeSessionId(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
            && !s.hasPrefix("-")
    }

    /// The "was running" offer for a restored pane (v0 of FR-26/27):
    /// nil when the pane had no adapter or the command is denylisted.
    ///
    /// `cwdUnavailable` is FR-25's second half: when the pane fell back to an
    /// ancestor/$HOME, cwd-dependent restores are disabled — `claude
    /// --continue` would resume the WRONG directory's most recent session and
    /// watcher argv routinely holds relative paths. `claude --resume <uuid>`
    /// (verified to work from any cwd) stays, with a caveat in the label; ssh
    /// reconnects are cwd-independent and stay too.
    public static func resumeOffer(for snap: SnapshotRow, cwdUnavailable: Bool = false)
        -> (label: String, command: String)? {
        let offer: (label: String, command: String)
        switch snap.adapter {
        case "claude":
            if let sessionId = snap.adapterState["sessionId"],
               isValidClaudeSessionId(sessionId) {
                var label = "claude (\(sessionId.prefix(8))…)"
                if cwdUnavailable { label += " — project directory unavailable" }
                offer = (label, "claude --resume \(sessionId)")
            } else if cwdUnavailable {
                return nil
            } else {
                offer = ("claude (most recent session here)", "claude --continue")
            }
        case "ssh", "watcher":
            if snap.adapter == "watcher", cwdUnavailable { return nil }
            guard !snap.argv.isEmpty, !isDenylisted(argv: snap.argv) else { return nil }
            let base = (snap.argv[0] as NSString).lastPathComponent
            let command = ([base] + snap.argv.dropFirst().map(shellQuote)).joined(separator: " ")
            offer = (base, command)
        default:
            return nil
        }
        return isDenylisted(offer.command) ? nil : offer
    }

    /// Wrapper commands that execute their arguments — their argv elements are
    /// commands in their own right and get the full denylist check.
    public static let wrapperNames: Set<String> = ["watch", "env", "nohup", "timeout", "xargs", "caffeinate"]

    /// FR-30 over raw captured argv, checked BEFORE shell-quoting composes the
    /// command line: quoting used to hide `curl … | sh` inside a single
    /// argument, and wrappers like `watch 'rm -rf x'` re-run their argument.
    public static func isDenylisted(argv: [String]) -> Bool {
        guard let first = argv.first, !first.isEmpty else { return true }
        let base = (first as NSString).lastPathComponent
        for arg in argv.dropFirst() {
            if arg.contains("\n") || arg.contains("\r") { return true }
            // A pipeline hidden inside one argument (defeats post-quoting split).
            if arg.contains("|"), isDenylisted(arg) { return true }
        }
        if wrapperNames.contains(base) {
            for arg in argv.dropFirst() where !arg.hasPrefix("-") {
                if isDenylisted(arg) { return true }
            }
        }
        return false
    }

    /// FR-30 hard denylist — checked before any offer, no override exists.
    public static func isDenylisted(_ command: String) -> Bool {
        // Multiline unknowns are denylisted outright (FR-30); a newline would
        // also defeat the ⌘R types-without-newline guarantee (FR-29).
        if command.contains("\n") || command.contains("\r") {
            return true
        }
        // `curl … | sh` patterns (FR-30): a downloader piped into any shell.
        let segments = command.split(separator: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if segments.count > 1 {
            let downloaders: Set<String> = ["curl", "wget", "fetch"]
            let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish"]
            let bases = segments.map { seg -> String in
                let first = seg.split(separator: " ").first.map(String.init) ?? ""
                return (first as NSString).lastPathComponent
            }
            if let dl = bases.firstIndex(where: { downloaders.contains($0) }),
               bases[(dl + 1)...].contains(where: { shells.contains($0) }) {
                return true
            }
        }
        let tokens = command.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return true }
        let base = (first as NSString).lastPathComponent
        if ["sudo", "rm", "dd", "kill", "shutdown"].contains(base) || base.hasPrefix("mkfs") {
            return true
        }
        if base == "git", tokens.contains("push"),
           tokens.contains(where: { $0 == "--force" || $0 == "-f" }) {
            return true
        }
        return false
    }

    public static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
