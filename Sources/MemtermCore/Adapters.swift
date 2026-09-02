import Foundation

// Compiled-in adapter classification (§8, FR-34/35/37/38): what was running
// in a pane, and the exact command that would bring it back. Offers are
// consent-gated (FR-29) — memterm NEVER auto-executes a captured command,
// and there is no setting to change that.
//
// Shape (extension-architecture stage 1): one protocol conformance per
// adapter behind FR-34's typed interface, explicitly registered in a
// compiled-in array. The `Adapters` facade keeps the public entry points
// (`classify`, `resumeOffer`) byte-for-byte compatible, and two invariants
// live in the facade ON PURPOSE, outside every adapter:
//
//   1. The FR-30 denylist. It runs BEFORE any offer exists — raw-argv check
//      ahead of command composition for re-exec adapters, composed-command
//      check on every candidate — and no adapter can skip, reorder, or
//      override it.
//   2. ~/.claude parsing (`claudeProjectSlug` / `claudeSessionId` /
//      `isValidClaudeSessionId`). Version-fragile knowledge stays in ONE
//      place (REQUIREMENTS §8); ClaudeAdapter calls it, never re-implements.

// MARK: - FR-34 typed adapter interface

/// Flat string map journaled in pane_snapshot.adapter_state.
public typealias AdapterState = [String: String]

/// What `detect` may look at. v0 carries argv + cwd (exe is argv[0]);
/// pid and process-tree fields arrive with later FRs without breaking
/// conformances.
public struct AdapterDetectContext {
    public let argv: [String]
    public let cwd: String?

    public init(argv: [String], cwd: String?) {
        self.argv = argv
        self.cwd = cwd
    }
}

/// FR-34 fidelity class: what a restore of this adapter's pane actually
/// recovers. Metadata for chips/labels — never consulted by the consent or
/// denylist paths.
public enum AdapterFidelity: String {
    /// The original session itself comes back (claude --resume <uuid>).
    case sessionResume = "session-resume"
    /// Identical re-exec of the captured argv; process-internal / remote
    /// state is honestly NOT restored (ssh reconnect, watcher re-run).
    case reexec
    /// A device reconnect ACTION — no command string exists at all (serial).
    case reconnect
    /// Ghost scrollback + cwd + fresh shell only.
    case snapshotOnly = "snapshot-only"
}

/// A candidate restore offer composed by an adapter. NOT yet consent-checked:
/// the `Adapters` facade gates every candidate through the FR-30 denylist
/// before it can become an offer, and core alone types it on ⌘R (FR-29).
public struct RestoreCommand: Equatable {
    public let label: String
    public let command: String

    public init(label: String, command: String) {
        self.label = label
        self.command = command
    }
}

/// FR-34: the typed, compiled-in adapter interface. Conformances are Swift
/// types registered in `Adapters.registry` — code-reviewed, never
/// string-matched, never registerable from outside this module.
public protocol PaneAdapter {
    /// The name journaled in pane_snapshot.adapter ("" = plain shell).
    static var name: String { get }

    /// FR-34 fidelity class of this adapter's restore.
    var fidelityClass: AdapterFidelity { get }

    /// True when restore re-executes captured argv verbatim. The facade then
    /// runs the raw-argv denylist (wrapper unwrap, quote-hidden pipelines)
    /// BEFORE this adapter is asked to compose anything.
    var restoresByReexec: Bool { get }

    /// Classify a foreground process; nil = not this adapter's process.
    func detect(_ context: AdapterDetectContext) -> AdapterState?

    /// Candidate restore offer for a snapshot; nil degrades the pane to
    /// snapshot-only restore. Composition only — the FR-30 denylist is the
    /// facade's job, structurally outside every conformance.
    func restoreCommand(for snapshot: SnapshotRow, cwdUnavailable: Bool) -> RestoreCommand?
}

extension PaneAdapter {
    /// FR-34 `degrade()`: in v0 every adapter degrades the same way — when
    /// `restoreCommand` yields nil the pane restores snapshot-only (ghost
    /// scrollback + cwd + fresh shell). Nothing is ever auto-executed on the
    /// degrade path either.
    public func degrade() -> AdapterFidelity { .snapshotOnly }

    /// FR-34 label/badge: the adapter's human name. Offer labels are richer
    /// and per-snapshot (see `RestoreCommand.label`).
    public var label: String { Self.name }
}

// MARK: - Conformances (one per adapter, compiled-in)

/// FR-35 — the Claude Code adapter (the hero). Detection recognizes both the
/// `claude` binary and its node entrypoint; session-id resolution delegates
/// to the single ~/.claude parsing site on `Adapters`.
public struct ClaudeAdapter: PaneAdapter {
    public static let name = "claude"
    public var fidelityClass: AdapterFidelity { .sessionResume }
    public var restoresByReexec: Bool { false }

    /// Injected for tests; defaults to the real ~/.claude/projects.
    public let projectsDir: URL

    public init(projectsDir: URL = Adapters.defaultClaudeProjectsDir) {
        self.projectsDir = projectsDir
    }

    public func detect(_ context: AdapterDetectContext) -> AdapterState? {
        guard let first = context.argv.first else { return nil }
        let base = (first as NSString).lastPathComponent
        guard base == "claude"
            || (base == "node" && context.argv.contains {
                $0.hasSuffix("/claude") || $0.contains("/.claude/")
            })
        else { return nil }
        var state: AdapterState = [:]
        if let cwd = context.cwd,
           let sessionId = Adapters.claudeSessionId(forCwd: cwd, projectsDir: projectsDir) {
            state["sessionId"] = sessionId
        }
        return state
    }

    /// v0 of FR-26/27 for claude, incl. FR-25's second half: on a fallback
    /// cwd, `claude --continue` would resume the WRONG directory's most
    /// recent session and is suppressed; `claude --resume <uuid>` (verified
    /// to work from any cwd) stays, with a caveat in the label.
    public func restoreCommand(for snapshot: SnapshotRow, cwdUnavailable: Bool) -> RestoreCommand? {
        if let sessionId = snapshot.adapterState["sessionId"],
           Adapters.isValidClaudeSessionId(sessionId) {
            var label = "claude (\(sessionId.prefix(8))…)"
            if cwdUnavailable { label += " — project directory unavailable" }
            return RestoreCommand(label: label, command: "claude --resume \(sessionId)")
        }
        if cwdUnavailable { return nil }
        return RestoreCommand(label: "claude (most recent session here)",
                              command: "claude --continue")
    }
}

/// FR-37 — SSH adapter: capture exact argv; restore by identical re-exec
/// ("reconnect" — remote session state is honestly not restored). Reconnects
/// are cwd-independent and survive a fallback cwd (FR-25).
public struct SSHAdapter: PaneAdapter {
    public static let name = "ssh"
    public var fidelityClass: AdapterFidelity { .reexec }
    public var restoresByReexec: Bool { true }

    public init() {}

    public func detect(_ context: AdapterDetectContext) -> AdapterState? {
        guard let first = context.argv.first,
              (first as NSString).lastPathComponent == "ssh" else { return nil }
        return [:]
    }

    public func restoreCommand(for snapshot: SnapshotRow, cwdUnavailable: Bool) -> RestoreCommand? {
        Adapters.reexecCandidate(argv: snapshot.argv)
    }
}

/// FR-38 — read-only watcher adapter (tmux-resurrect's battle-tested set).
/// Watcher argv routinely holds relative paths, so a fallback cwd suppresses
/// the offer entirely (FR-25).
public struct WatcherAdapter: PaneAdapter {
    public static let name = "watcher"
    public var fidelityClass: AdapterFidelity { .reexec }
    public var restoresByReexec: Bool { true }

    public init() {}

    public func detect(_ context: AdapterDetectContext) -> AdapterState? {
        guard let first = context.argv.first,
              Adapters.watcherNames.contains((first as NSString).lastPathComponent)
        else { return nil }
        return [:]
    }

    public func restoreCommand(for snapshot: SnapshotRow, cwdUnavailable: Bool) -> RestoreCommand? {
        cwdUnavailable ? nil : Adapters.reexecCandidate(argv: snapshot.argv)
    }
}

/// The 'serial' conformance. Serial panes are created by the serial UI and
/// journal their own state (`SerialAdapter.journalState`) — never classified
/// from argv — and restore via `SerialAdapter.reconnectOffer`, a reconnect
/// ACTION with no command string, handled by the app BEFORE `resumeOffer` is
/// consulted. Both methods therefore return nil by design: the FR-30 command
/// path stays untouched for serial (asserted in tests).
public struct SerialPaneAdapter: PaneAdapter {
    public static let name = SerialAdapter.name
    public var fidelityClass: AdapterFidelity { .reconnect }
    public var restoresByReexec: Bool { false }

    public init() {}

    public func detect(_ context: AdapterDetectContext) -> AdapterState? { nil }

    public func restoreCommand(for snapshot: SnapshotRow, cwdUnavailable: Bool) -> RestoreCommand? { nil }
}

/// The implicit fallback: a pane whose foreground process no adapter claims
/// journals adapter="" and restores snapshot-only. Never detects — `classify`
/// returns nil for non-adapter processes and MemoryEngine writes the empty
/// adapter name, exactly as before this refactor.
public struct PlainShellAdapter: PaneAdapter {
    public static let name = ""
    public var fidelityClass: AdapterFidelity { .snapshotOnly }
    public var restoresByReexec: Bool { false }

    public init() {}

    public func detect(_ context: AdapterDetectContext) -> AdapterState? { nil }

    public func restoreCommand(for snapshot: SnapshotRow, cwdUnavailable: Bool) -> RestoreCommand? { nil }
}

// MARK: - Facade: registry, classification, consent-gated offers, denylist

public enum Adapters {

    public static let watcherNames: Set<String> = ["tail", "less", "more", "man", "htop", "top", "watch"]

    /// Test seam (stage 3): MEMTERM_CLAUDE_DIR points the ONE ~/.claude
    /// parsing site at a fixture tree (<dir>/projects, <dir>/sessions) so
    /// probes exercise the kit's claude.* surface hermetically. Read per
    /// call — a probe leg may set it mid-process — and never set outside
    /// automated runs; the real app resolves ~/.claude as ever.
    public static var claudeDirOverride: URL? {
        guard let dir = ProcessInfo.processInfo.environment["MEMTERM_CLAUDE_DIR"],
              !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    public static var defaultClaudeProjectsDir: URL {
        if let override = claudeDirOverride {
            return override.appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// The compiled-in registry (FR-34: the allowlist is code-reviewed, not
    /// string-matched; nothing outside this module can register into it).
    /// Detection order = declaration order: claude before the generic
    /// matchers; serial and plain-shell never detect.
    public static func registry(claudeProjectsDir: URL = defaultClaudeProjectsDir)
        -> [any PaneAdapter] {
        [ClaudeAdapter(projectsDir: claudeProjectsDir),
         SSHAdapter(),
         WatcherAdapter(),
         SerialPaneAdapter(),
         PlainShellAdapter()]
    }

    /// Registry lookup by journaled adapter name.
    public static func adapter(named name: String,
                               claudeProjectsDir: URL = defaultClaudeProjectsDir)
        -> (any PaneAdapter)? {
        registry(claudeProjectsDir: claudeProjectsDir).first { type(of: $0).name == name }
    }

    /// Classifies a foreground process; returns (adapter, adapter_state) or nil.
    public static func classify(argv: [String], cwd: String?,
                                claudeProjectsDir: URL = defaultClaudeProjectsDir)
        -> (adapter: String, state: [String: String])? {
        guard let first = argv.first, !first.isEmpty else { return nil }
        let context = AdapterDetectContext(argv: argv, cwd: cwd)
        for adapter in registry(claudeProjectsDir: claudeProjectsDir) {
            if let state = adapter.detect(context) {
                return (type(of: adapter).name, state)
            }
        }
        return nil
    }

    /// The "was running" offer for a restored pane (v0 of FR-26/27):
    /// nil when the pane had no adapter, the adapter degrades (snapshot-only),
    /// or the command is denylisted.
    ///
    /// FR-30 precedence lives HERE, outside every adapter, and is not
    /// reachable from any conformance: the raw-argv denylist (wrapper unwrap,
    /// quote-hidden pipelines) runs BEFORE a re-exec adapter composes
    /// anything, and the composed-command denylist gates every candidate
    /// before it becomes an offer.
    ///
    /// `cwdUnavailable` is FR-25's second half: when the pane fell back to an
    /// ancestor/$HOME, cwd-dependent restores are disabled — each adapter's
    /// `restoreCommand` documents its own handling.
    public static func resumeOffer(for snap: SnapshotRow, cwdUnavailable: Bool = false)
        -> (label: String, command: String)? {
        guard let adapter = adapter(named: snap.adapter) else { return nil }
        if adapter.restoresByReexec {
            guard !snap.argv.isEmpty, !isDenylisted(argv: snap.argv) else { return nil }
        }
        guard let offer = adapter.restoreCommand(for: snap, cwdUnavailable: cwdUnavailable)
        else { return nil }
        return isDenylisted(offer.command) ? nil : (offer.label, offer.command)
    }

    /// Composes a re-exec candidate from captured argv: basename + each
    /// argument shell-quoted. Shared by the re-exec adapters (ssh, watcher);
    /// callers reach it only through `resumeOffer`, which has already run the
    /// raw-argv denylist.
    public static func reexecCandidate(argv: [String]) -> RestoreCommand? {
        guard let first = argv.first else { return nil }
        let base = (first as NSString).lastPathComponent
        let command = ([base] + argv.dropFirst().map(shellQuote)).joined(separator: " ")
        return RestoreCommand(label: base, command: command)
    }

    // MARK: ~/.claude parsing — the ONE version-fragile site (§8)

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

    // MARK: ~/.claude scanning — SAME one version-fragile site (§8, FR-35)
    //
    // The ExtensionKit claude.* surface (kit v0): typed project/session
    // scans the app's Host implementation maps into kit types, so extensions
    // never touch raw ~/.claude paths or fork jsonl parsing. Everything here
    // is read-only and version-TOLERANT per the FR-35 discipline: undocumented
    // formats are parsed defensively — a malformed file or line is skipped,
    // never a crash, never a guess — and each session surfaces the Claude
    // Code `version` that wrote it so consumers can gate features per release.

    /// One project directory under ~/.claude/projects. The slug encoding is
    /// lossy (cwd → every non-alphanumeric becomes '-'), so it is never
    /// inverted into a path (§8); per-session cwd carries the honest path.
    public struct ClaudeProjectScan: Equatable {
        public let slug: String
        public let sessionCount: Int
        public let lastActivity: Date?
    }

    public struct ClaudeSessionScan: Equatable {
        public let id: String
        public let projectSlug: String
        /// Session jsonl mtime — when Claude last wrote.
        public let lastActivity: Date
        /// The live-session registry (~/.claude/sessions/<pid>.json — FR-35's
        /// primary capture signal) names this session under a pid that is
        /// still alive.
        public let isLive: Bool
        /// HEURISTIC: live but jsonl-quiet past the idle threshold — a
        /// working Claude writes its jsonl continuously, so a live-but-quiet
        /// session is most likely waiting on the user (prompt/permission).
        public let needsAttention: Bool
        public let lastPrompt: String?
        public let cwd: String?
        public let claudeVersion: String?
    }

    public static var defaultClaudeSessionsDir: URL {
        if let override = claudeDirOverride {
            return override.appendingPathComponent("sessions")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
    }

    /// Live-but-quiet-this-long ⇒ needsAttention (see ClaudeSessionScan).
    public static let claudeAttentionIdleThreshold: TimeInterval = 30

    /// All project slugs under the projects dir, most recently active first.
    /// A directory with no session jsonls still lists (sessionCount 0).
    public static func claudeProjectScans(projectsDir: URL = defaultClaudeProjectsDir)
        -> [ClaudeProjectScan] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var scans: [ClaudeProjectScan] = []
        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let jsonls = sessionJsonls(in: dir)
            scans.append(ClaudeProjectScan(
                slug: dir.lastPathComponent,
                sessionCount: jsonls.count,
                lastActivity: jsonls.map { mtime($0) }.max()))
        }
        return scans.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    /// One project's sessions, most recently active first, with liveness and
    /// needs-attention resolved against the live-session registry.
    public static func claudeSessionScans(projectSlug: String,
                                          projectsDir: URL = defaultClaudeProjectsDir,
                                          sessionsDir: URL = defaultClaudeSessionsDir,
                                          now: Date = Date(),
                                          attentionIdleThreshold: TimeInterval = claudeAttentionIdleThreshold)
        -> [ClaudeSessionScan] {
        let dir = projectsDir.appendingPathComponent(projectSlug)
        let live = claudeLiveRegistry(sessionsDir: sessionsDir)
        var scans: [ClaudeSessionScan] = []
        for file in sessionJsonls(in: dir) {
            let id = file.deletingPathExtension().lastPathComponent
            guard isValidClaudeSessionId(id) else { continue }
            let activity = mtime(file)
            let registry = live[id]
            let isLive = registry != nil
            let tail = claudeJsonlTailScan(file)
            scans.append(ClaudeSessionScan(
                id: id,
                projectSlug: projectSlug,
                lastActivity: activity,
                isLive: isLive,
                needsAttention: isLive
                    && now.timeIntervalSince(activity) > attentionIdleThreshold,
                lastPrompt: tail.lastPrompt,
                cwd: registry?.cwd ?? tail.cwd,
                claudeVersion: registry?.version ?? tail.version))
        }
        return scans.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The live-session registry: ~/.claude/sessions/<pid>.json records
    /// ({pid, sessionId, cwd, version, …}) whose pid still names a running
    /// process (kill(pid, 0): success or EPERM = alive). Undocumented format —
    /// any record missing the fields we need is skipped.
    static func claudeLiveRegistry(sessionsDir: URL)
        -> [String: (cwd: String?, version: String?)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil) else { return [:] }
        var registry: [String: (cwd: String?, version: String?)] = [:]
        for file in entries where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count < 1_048_576,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let record = object as? [String: Any],
                  let sessionId = record["sessionId"] as? String,
                  isValidClaudeSessionId(sessionId),
                  let pid = record["pid"] as? Int, pid > 0
            else { continue }
            let alive = kill(pid_t(pid), 0) == 0 || errno == EPERM
            guard alive else { continue }
            registry[sessionId] = (cwd: record["cwd"] as? String,
                                   version: record["version"] as? String)
        }
        return registry
    }

    /// Session jsonl files (files only, .jsonl extension) in one project dir.
    private static func sessionJsonls(in dir: URL) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
        else { return [] }
        return files.filter {
            $0.pathExtension == "jsonl"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    /// Reads the TAIL of a session jsonl (bounded — jsonls grow to many MB)
    /// and scans lines newest-first for the user's last prompt, the session's
    /// cwd, and the writing Claude Code version. Every line is parsed
    /// defensively: malformed JSON or unknown shapes are skipped.
    static func claudeJsonlTailScan(_ file: URL, maxTailBytes: Int = 262_144)
        -> (lastPrompt: String?, cwd: String?, version: String?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return (nil, nil, nil)
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            return (nil, nil, nil)
        }
        var lastPrompt: String?
        var cwd: String?
        var version: String?
        for line in text.split(separator: "\n").reversed() {
            if lastPrompt != nil, cwd != nil, version != nil { break }
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let record = object as? [String: Any] else { continue }
            if lastPrompt == nil, record["type"] as? String == "last-prompt",
               let prompt = record["lastPrompt"] as? String, !prompt.isEmpty {
                lastPrompt = prompt
            }
            if cwd == nil, let recordCwd = record["cwd"] as? String, !recordCwd.isEmpty {
                cwd = recordCwd
            }
            if version == nil, let v = record["version"] as? String, !v.isEmpty {
                version = v
            }
        }
        return (lastPrompt, cwd, version)
    }

    // MARK: FR-30 denylist — checked before any offer, outside the adapters

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
