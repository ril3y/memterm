import Foundation

// FR-61 / FR-62 — always-on agent status (spec:
// docs/superpowers/specs/2026-11-20-agent-status-design.md).
//
// Pure pieces only; the app feeds them a pane's agent kind (from the 2 s
// process capture), its terminal title, its visible screen text and any OSC
// 7501 self-report, and renders what comes back. Nothing here types or runs
// anything — status is read-only (consent invariant).

/// A coding agent memterm recognizes by its foreground process.
public enum AgentKind: String, CaseIterable, Sendable {
    case claude, codex, gemini

    /// The agent behind a journaled adapter name, if that adapter is an agent.
    public init?(adapterName: String) {
        self.init(rawValue: adapterName)
    }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }
}

/// herdr's screen states. `unknown` comes only from skip-update rules.
public enum AgentState: String, Sendable {
    case working, blocked, idle, unknown
}

/// One evaluation of an agent pane.
public struct AgentDetection: Equatable, Sendable {
    public var state: AgentState
    /// A viewer (transcript, picker) is on screen: keep the previous state.
    public var skipUpdate: Bool
    /// The screen visibly shows the agent's idle prompt.
    public var visibleIdle: Bool
    /// The screen visibly shows a prompt that needs the user.
    public var visibleBlocker: Bool
    /// The winning rule, nil for the no-match fallback.
    public var ruleId: String?

    public init(state: AgentState, skipUpdate: Bool = false, visibleIdle: Bool = false,
                visibleBlocker: Bool = false, ruleId: String? = nil) {
        self.state = state
        self.skipUpdate = skipUpdate
        self.visibleIdle = visibleIdle
        self.visibleBlocker = visibleBlocker
        self.ruleId = ruleId
    }
}

/// What a tab, a workspace chip, or the Dock shows for agents.
public enum AgentBadge: Int, Comparable, Sendable {
    case none = 0, working, done, blocked

    public static func < (a: AgentBadge, b: AgentBadge) -> Bool { a.rawValue < b.rawValue }

    /// Roll-up for a tab or workspace: blocked > done > working > none.
    public static func strongest<S: Sequence>(_ badges: S) -> AgentBadge where S.Element == AgentBadge {
        badges.max() ?? .none
    }

    /// What a tab shows: the tab you're on shows only `blocked` (a waiting
    /// agent must stay visible; working/done there are being watched).
    public func shownOnTab(selected: Bool) -> AgentBadge {
        selected && self != .blocked ? .none : self
    }
}

// MARK: - Detection

public enum AgentStatusDetector {

    /// Classifies a known agent's pane. `screen` is the visible grid, one
    /// line per row joined by "\n".
    public static func detect(kind: AgentKind, title: String, screen: String) -> AgentDetection {
        var best: AgentRule?
        for rule in AgentRules.rules(for: kind) {
            if let b = best, b.priority >= rule.priority { continue }
            let text = region(rule.region, title: title, screen: screen)
            if gateMatches(rule.gate, text: text, lower: text.lowercased()) {
                best = rule
            }
        }
        guard let rule = best else {
            // herdr: a known agent with no matching rule reads as plain idle.
            return AgentDetection(state: .idle)
        }
        return AgentDetection(state: rule.state,
                              skipUpdate: rule.skipUpdate,
                              visibleIdle: rule.visibleIdle && rule.state == .idle,
                              visibleBlocker: rule.visibleBlocker && rule.state == .blocked,
                              ruleId: rule.id)
    }

    static func region(_ region: AgentRegion, title: String, screen: String) -> String {
        switch region {
        case .oscTitle: return title
        case .wholeRecent: return screen
        case .bottomNonEmptyLines(let n): return AgentRegions.bottomNonEmptyLines(screen, n)
        case .topNonEmptyLines(let n): return AgentRegions.topNonEmptyLines(screen, n)
        case .afterLastHorizontalRule: return AgentRegions.afterLastHorizontalRule(screen)
        case .promptBoxBody: return AgentRegions.promptBoxBody(screen) ?? ""
        case .lastNonEmptyAbovePromptBox:
            return AgentRegions.lastNonEmptyLine(AgentRegions.abovePromptBox(screen))
        case .afterLastPromptMarker: return AgentRegions.afterLastPromptMarker(screen)
        case .beforeCurrentPromptMarker: return AgentRegions.beforeCurrentPromptMarker(screen)
        case .wholeRecentWithoutCurrentPromptMarker:
            return AgentRegions.currentPromptIndex(AgentRegions.lines(screen)) == nil ? screen : ""
        }
    }

    static func gateMatches(_ gate: AgentGate, text: String, lower: String) -> Bool {
        for needle in gate.contains where !lower.contains(needle.lowercased()) { return false }
        for pattern in gate.regex where !matches(pattern, text) { return false }
        if !gate.lineRegex.isEmpty {
            let lines = AgentRegions.lines(text)
            for pattern in gate.lineRegex where !lines.contains(where: { matches(pattern, String($0)) }) {
                return false
            }
        }
        for nested in gate.all where !gateMatches(nested, text: text, lower: lower) { return false }
        if !gate.any.isEmpty && !gate.any.contains(where: { gateMatches($0, text: text, lower: lower) }) {
            return false
        }
        if gate.not.contains(where: { gateMatches($0, text: text, lower: lower) }) { return false }
        return true
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let re = AgentRegexCache.regex(pattern) else { return false }
        let ns = text as NSString
        return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }
}

/// herdr's screen regions (src/detect/manifest.rs), over "\n"-joined text.
/// Line splitting follows Rust's `str::lines`: a trailing newline does not
/// start an extra empty line, and a trailing "\r" is dropped.
public enum AgentRegions {

    static func lines(_ text: String) -> [Substring] {
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts.map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
    }

    /// The text from line `index` to the end, newlines kept.
    private static func from(_ text: String, line index: Int) -> String {
        guard index > 0 else { return text }
        var seen = 0
        var cut = text.endIndex
        for i in text.indices where text[i] == "\n" {
            seen += 1
            if seen == index { cut = text.index(after: i); break }
        }
        return seen == index ? String(text[cut...]) : ""
    }

    /// The text before line `index` (each kept line ends with "\n").
    private static func upTo(_ text: String, line index: Int) -> String {
        guard index > 0 else { return "" }
        var seen = 0
        for i in text.indices where text[i] == "\n" {
            seen += 1
            if seen == index { return String(text[...i]) }
        }
        return text
    }

    public static func bottomNonEmptyLines(_ text: String, _ count: Int) -> String {
        let ls = lines(text)
        let nonEmpty = ls.indices.reversed().filter { !ls[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard count > 0, let start = nonEmpty.prefix(count).last else { return "" }
        return from(text, line: start)
    }

    public static func topNonEmptyLines(_ text: String, _ count: Int) -> String {
        let ls = lines(text)
        let nonEmpty = ls.indices.filter { !ls[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard count > 0, let end = nonEmpty.prefix(count).last else { return "" }
        return upTo(text, line: end + 1)
    }

    public static func isHorizontalRule<S: StringProtocol>(_ line: S) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let ruleChars = trimmed.prefix { $0 == "─" }.count
        guard ruleChars > 0 else { return false }
        let suffix = trimmed.dropFirst(ruleChars).drop { $0.isWhitespace }
        return suffix.isEmpty || ruleChars >= 3
    }

    public static func afterLastHorizontalRule(_ text: String) -> String {
        let ls = lines(text)
        guard let last = ls.lastIndex(where: { isHorizontalRule($0) }) else { return text }
        return from(text, line: last + 1)
    }

    private static func promptBoxTop(_ ls: [Substring]) -> Int? {
        var count = 0
        for i in ls.indices.reversed() where isHorizontalRule(ls[i]) {
            count += 1
            if count == 2 { return i }
        }
        return nil
    }

    public static func promptBoxBody(_ text: String) -> String? {
        let ls = lines(text)
        guard let top = promptBoxTop(ls) else { return nil }
        let end = ls[(top + 1)...].firstIndex(where: { isHorizontalRule($0) }) ?? ls.count
        return upTo(from(text, line: top + 1), line: end - top - 1)
    }

    public static func abovePromptBox(_ text: String) -> String {
        let ls = lines(text)
        guard let top = promptBoxTop(ls) else { return text }
        return upTo(text, line: top)
    }

    public static func lastNonEmptyLine(_ text: String) -> String {
        lines(text).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
    }

    // Codex prompt markers ("›" lines) and response block markers.

    static func isCodexPrompt<S: StringProtocol>(_ line: S) -> Bool {
        line == "›" || line.hasPrefix("› ")
    }

    static func isCodexBlockMarker<S: StringProtocol>(_ line: S) -> Bool {
        guard let c = line.first else { return false }
        return c == "•" || c == "■" || c == "✗" || c == "✓"
    }

    static func currentPromptIndex(_ ls: [Substring]) -> Int? {
        guard let p = ls.lastIndex(where: { isCodexPrompt($0) }) else { return nil }
        if ls[(p + 1)...].contains(where: { isCodexBlockMarker($0) }) { return nil }
        return p
    }

    public static func afterLastPromptMarker(_ text: String) -> String {
        let ls = lines(text)
        guard let p = ls.lastIndex(where: { isCodexPrompt($0) }) else { return text }
        return from(text, line: p + 1)
    }

    public static func beforeCurrentPromptMarker(_ text: String) -> String {
        guard let p = currentPromptIndex(lines(text)) else { return text }
        return upTo(text, line: p)
    }
}

// MARK: - OSC 7501 (herdr's Program Status Protocol)

/// `ESC ] 7501 ; state=…:kind=…:progress=…:app=…:title=<b64>:msg=<b64> ST`.
public struct ProgramStatus: Equatable, Sendable {
    public var state: String
    public var kind: String?
    public var progress: Int?
    public var app: String
    public var title: String
    public var msg: String
    /// Reports with an `id` describe a sub-task; only root reports drive a pane.
    public var isSubRecord: Bool

    public var isClear: Bool { state == "clear" }

    /// done/idle → idle, working → working, blocked/error → blocked.
    public var agentState: AgentState? {
        switch state {
        case "working": return .working
        case "blocked", "error": return .blocked
        case "idle", "done": return .idle
        default: return nil
        }
    }

    /// Parses the payload after "7501;". Nil for garbage or a missing state.
    public static func parse(_ payload: String) -> ProgramStatus? {
        guard !payload.isEmpty, payload.utf8.count <= 4096 else { return nil }
        var fields: [String: String] = [:]
        for part in payload.split(separator: ":") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<eq])] = String(part[part.index(after: eq)...])
        }
        guard let state = fields["state"], !state.isEmpty,
              state.allSatisfy({ $0.isLetter }) else { return nil }
        func b64(_ key: String) -> String {
            guard let raw = fields[key], let data = Data(base64Encoded: raw) else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        let progress = fields["progress"].flatMap(Int.init).flatMap { (0...100).contains($0) ? $0 : nil }
        return ProgramStatus(state: state,
                             kind: fields["kind"].flatMap { $0.isEmpty ? nil : $0 },
                             progress: progress,
                             app: fields["app"] ?? "",
                             title: b64("title"),
                             msg: b64("msg"),
                             isSubRecord: !(fields["id"] ?? "").isEmpty)
    }

    public var detection: AgentDetection? {
        guard let s = agentState else { return nil }
        return AgentDetection(state: s, visibleIdle: s == .idle, visibleBlocker: s == .blocked,
                              ruleId: "osc7501")
    }
}

// MARK: - Attention (done, hysteresis, alerts)

/// Per-pane agent state over time: herdr's pending-idle hysteresis, the
/// derived `done`, and the FR-62 alert rule ("needing you always alerts;
/// finishing alerts only if the person wasn't looking").
public struct AgentAttentionTracker {

    public enum Alert: Equatable, Sendable { case blocked, done }

    /// herdr src/pane/agent_detection.rs: working → plain idle waits for
    /// 3 confirmations or 700 ms.
    public static let pendingIdleConfirmations = 3
    public static let pendingIdleCap: TimeInterval = 0.7

    struct Pane {
        var kind: AgentKind
        var state: AgentState = .idle
        var unseenDone = false
        var pendingIdleSince: TimeInterval?
        var pendingIdleConfirmations = 0
    }

    private var panes: [String: Pane] = [:]

    public init() {}

    /// Feeds one evaluation. `kind == nil` means the pane no longer runs an
    /// agent: its state is dropped without an alert. Returns the alert to
    /// raise, if any.
    public mutating func observe(pane id: String, kind: AgentKind?, detection: AgentDetection?,
                                 looking: Bool, now: TimeInterval) -> Alert? {
        guard let kind else {
            panes[id] = nil
            return nil
        }
        var p = panes[id] ?? Pane(kind: kind)
        if p.kind != kind { p = Pane(kind: kind) }
        defer { panes[id] = p }
        guard let d = detection, !d.skipUpdate, d.state != .unknown else { return nil }

        let prev = p.state
        var next = d.state

        // Pending idle: hold a working → idle change that lacks visible idle
        // chrome, so the gap between two tool calls is not a "finish".
        if prev == .working && d.state == .idle && !d.visibleIdle && !d.visibleBlocker {
            if let since = p.pendingIdleSince {
                p.pendingIdleConfirmations += 1
                if now - since >= Self.pendingIdleCap
                    || p.pendingIdleConfirmations >= Self.pendingIdleConfirmations {
                    p.pendingIdleSince = nil
                    p.pendingIdleConfirmations = 0
                } else {
                    next = .working
                }
            } else {
                p.pendingIdleSince = now
                p.pendingIdleConfirmations = 0
                next = .working
            }
        } else {
            p.pendingIdleSince = nil
            p.pendingIdleConfirmations = 0
        }

        p.state = next
        if next == prev { return nil }

        if next == .working || next == .blocked { p.unseenDone = false }
        if next == .blocked { return .blocked }
        if next == .idle && (prev == .working || prev == .blocked) && !looking {
            p.unseenDone = true
            return .done
        }
        return nil
    }

    /// The user looked at the pane. Returns true when that cleared a `done`.
    @discardableResult
    public mutating func markSeen(pane id: String) -> Bool {
        guard panes[id]?.unseenDone == true else { return false }
        panes[id]?.unseenDone = false
        return true
    }

    public mutating func remove(pane id: String) {
        panes[id] = nil
    }

    public func badge(of id: String) -> AgentBadge {
        guard let p = panes[id] else { return .none }
        switch p.state {
        case .blocked: return .blocked
        case .working: return .working
        case .idle, .unknown: return p.unseenDone ? .done : .none
        }
    }

    public func kind(of id: String) -> AgentKind? { panes[id]?.kind }

    /// Panes that need the user: blocked, or finished while unseen (Dock badge).
    public var needsYouCount: Int {
        panes.values.filter { $0.state == .blocked || $0.unseenDone }.count
    }

    public var trackedPanes: [String] { Array(panes.keys) }
}
