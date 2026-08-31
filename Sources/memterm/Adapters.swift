import Foundation

// Compiled-in adapter classification (§8, v0 of FR-34/35/37/38): what was
// running in a pane, and the exact command that would bring it back. Offers
// are consent-gated (FR-29) — memterm NEVER auto-executes a captured command,
// and there is no setting to change that.

enum Adapters {

    static let watcherNames: Set<String> = ["tail", "less", "more", "man", "htop", "top", "watch"]

    /// Classifies a foreground process; returns (adapter, adapter_state) or nil.
    static func classify(argv: [String], cwd: String?) -> (adapter: String, state: [String: String])? {
        guard let first = argv.first, !first.isEmpty else { return nil }
        let base = (first as NSString).lastPathComponent

        if base == "claude" || (base == "node" && argv.contains { $0.hasSuffix("/claude") || $0.contains("/.claude/") }) {
            var state: [String: String] = [:]
            if let cwd, let sessionId = claudeSessionId(forCwd: cwd) {
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

    /// Most-recently-modified session jsonl under ~/.claude/projects/<encoded-cwd>/.
    /// Encoding: every non-alphanumeric character becomes '-'.
    static func claudeSessionId(forCwd cwd: String) -> String? {
        var encoded = ""
        for scalar in cwd.unicodeScalars {
            encoded.unicodeScalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : "-")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded)")
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

    /// The "was running" offer for a restored pane (v0 of FR-26/27):
    /// nil when the pane had no adapter or the command is denylisted.
    static func resumeOffer(for snap: SnapshotRow) -> (label: String, command: String)? {
        let offer: (label: String, command: String)
        switch snap.adapter {
        case "claude":
            if let sessionId = snap.adapterState["sessionId"], !sessionId.isEmpty {
                offer = ("claude (\(sessionId.prefix(8))…)", "claude --resume \(sessionId)")
            } else {
                offer = ("claude (most recent session here)", "claude --continue")
            }
        case "ssh", "watcher":
            guard !snap.argv.isEmpty else { return nil }
            let base = (snap.argv[0] as NSString).lastPathComponent
            let command = ([base] + snap.argv.dropFirst().map(shellQuote)).joined(separator: " ")
            offer = (base, command)
        default:
            return nil
        }
        return isDenylisted(offer.command) ? nil : offer
    }

    /// FR-30 hard denylist — checked before any offer, no override exists.
    static func isDenylisted(_ command: String) -> Bool {
        // Multiline unknowns are denylisted outright (FR-30); a newline would
        // also defeat the ⌘R types-without-newline guarantee (FR-29).
        if command.contains("\n") || command.contains("\r") {
            return true
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

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
