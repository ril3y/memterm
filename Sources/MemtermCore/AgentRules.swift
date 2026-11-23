import Foundation

// FR-61 — agent screen rules.
//
// Ported by hand from herdr's detection manifests (github.com/herdrdev/herdr
// at e8d7d97, src/detect/manifests/*.toml), Copyright the herdr authors,
// licensed under the Apache License 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
// Ported versions: claude.toml 2026.10.11.1, codex.toml 2026.10.11.1,
// gemini.toml 2026.06.10.1. Changes from the originals: the TOML became Swift
// values, and claude's `osc_progress_idle` rule is left out (memterm does not
// feed OSC 9;4 progress to the detector). Patterns, priorities, regions and
// gate structure are otherwise verbatim, so a future manifest bump is a
// line-by-line diff against these tables.
//
// Semantics (herdr src/detect/manifest.rs, kept exactly):
// - `contains`: every needle must appear in the region, case-insensitively;
// - `regex`: every pattern must match the region text;
// - `lineRegex`: every pattern must match at least one line of the region;
// - `all` / `any` / `not`: nested gates (any = at least one; not = none);
// - the matching rule with the highest priority wins; ties keep the earlier rule.

public enum AgentRegion: Equatable, Sendable {
    case oscTitle
    case wholeRecent
    case bottomNonEmptyLines(Int)
    case topNonEmptyLines(Int)
    case afterLastHorizontalRule
    case promptBoxBody
    case lastNonEmptyAbovePromptBox
    case afterLastPromptMarker
    case beforeCurrentPromptMarker
    case wholeRecentWithoutCurrentPromptMarker
}

public struct AgentGate: Sendable {
    public var contains: [String] = []
    public var regex: [String] = []
    public var lineRegex: [String] = []
    public var all: [AgentGate] = []
    public var any: [AgentGate] = []
    public var not: [AgentGate] = []

    public init(contains: [String] = [], regex: [String] = [], lineRegex: [String] = [],
                all: [AgentGate] = [], any: [AgentGate] = [], not: [AgentGate] = []) {
        self.contains = contains
        self.regex = regex
        self.lineRegex = lineRegex
        self.all = all
        self.any = any
        self.not = not
    }
}

public struct AgentRule: Sendable {
    public var id: String
    public var state: AgentState
    public var priority: Int
    public var region: AgentRegion
    public var visibleIdle = false
    public var visibleBlocker = false
    public var skipUpdate = false
    public var gate: AgentGate

    public init(id: String, state: AgentState, priority: Int, region: AgentRegion = .wholeRecent,
                visibleIdle: Bool = false, visibleBlocker: Bool = false, skipUpdate: Bool = false,
                gate: AgentGate) {
        self.id = id
        self.state = state
        self.priority = priority
        self.region = region
        self.visibleIdle = visibleIdle
        self.visibleBlocker = visibleBlocker
        self.skipUpdate = skipUpdate
        self.gate = gate
    }
}

private typealias G = AgentGate

public enum AgentRules {

    public static func rules(for kind: AgentKind) -> [AgentRule] {
        switch kind {
        case .claude: return claude
        case .codex: return codex
        case .gemini: return gemini
        }
    }

    /// Patterns that fail to compile under ICU (tests assert this is empty:
    /// herdr writes Rust-regex syntax, and the port must stay in the common
    /// subset).
    public static func compileFailures(for kind: AgentKind) -> [String] {
        var failures: [String] = []
        func visit(_ gate: AgentGate, _ id: String) {
            for p in gate.regex + gate.lineRegex where AgentRegexCache.regex(p) == nil {
                failures.append("\(id): \(p)")
            }
            (gate.all + gate.any + gate.not).forEach { visit($0, id) }
        }
        rules(for: kind).forEach { visit($0.gate, $0.id) }
        return failures
    }

    // MARK: claude.toml 2026.10.11.1

    static let claude: [AgentRule] = [
        AgentRule(id: "osc_title_working", state: .working, priority: 1100, region: .oscTitle,
                  gate: G(regex: [#"^[\x{2800}-\x{28FF}\x{25D0}-\x{25D3}] "#])),
        AgentRule(id: "live_turn_working", state: .working, priority: 970,
                  region: .bottomNonEmptyLines(12),
                  gate: G(any: [
                      G(lineRegex: [#"^\s*[⏸⏵].*esc to interrupt(?:\s|·|$)"#]),
                      G(lineRegex: [#"^\s*[\x{002A}\x{00B7}\x{2722}\x{2733}\x{2736}\x{273B}\x{273D}]\s+\S.*…(?:\s+\(\d+[smh](?:\s|·)|\s*$)"#]),
                  ])),
        AgentRule(id: "background_agents_working", state: .working, priority: 965,
                  region: .lastNonEmptyAbovePromptBox,
                  gate: G(lineRegex: [#"^\s*[\x{002A}\x{00B7}\x{2722}\x{2736}\x{273B}\x{273D}]\s+Waiting for [1-9]\d* background agents? to finish\s*$"#])),
        AgentRule(id: "background_mcp_task_working", state: .working, priority: 965,
                  region: .bottomNonEmptyLines(12),
                  gate: G(regex: [#"(?m)^[\x{002A}\x{00B7}\x{2722}\x{2736}\x{273B}\x{273D}][ \t]+\S[^\n]*?(?:\n[ \t]+[^\n]*?){0,3}·(?:[ \t]+|\n[ \t]*)[1-9]\d*(?:[ \t]+|\n[ \t]*)MCP(?:[ \t]+|\n[ \t]*)tasks?(?:[ \t]+|\n[ \t]*)still(?:[ \t]+|\n[ \t]*)running[ \t]*$"#],
                          not: [
                              G(contains: ["do you want to proceed?"]),
                              G(contains: ["esc to cancel"]),
                              G(contains: ["waiting for permission"]),
                              G(contains: ["do you want to allow this connection?"]),
                              G(contains: ["tab to amend"]),
                              G(contains: ["ctrl+e to explain"]),
                          ])),
        AgentRule(id: "btw_overlay_working", state: .working, priority: 975,
                  region: .bottomNonEmptyLines(5),
                  gate: G(lineRegex: [#"^\s*/btw(?:\s|$)"#, #"(?i)esc to close\s*$"#])),
        AgentRule(id: "transcript_viewer", state: .unknown, priority: 1000,
                  region: .bottomNonEmptyLines(3), skipUpdate: true,
                  gate: G(contains: ["showing detailed transcript"],
                          any: [
                              G(contains: ["ctrl+o", "to toggle"]),
                              G(contains: ["ctrl+e", "show all"]),
                              G(contains: ["ctrl+e", "collapse"]),
                              G(contains: ["↑↓ scroll"]),
                              G(contains: ["? for shortcuts"]),
                          ])),
        AgentRule(id: "live_blocked_form", state: .blocked, priority: 980,
                  region: .afterLastHorizontalRule, visibleBlocker: true,
                  gate: G(contains: ["esc to cancel"],
                          any: [
                              G(contains: ["enter to confirm"]),
                              G(contains: ["enter to select"], any: [
                                  G(contains: ["tab/arrow keys to navigate"]),
                                  G(contains: ["arrow keys to navigate"]),
                                  G(contains: ["arrows to navigate"]),
                                  G(contains: ["↑/↓ to navigate"]),
                                  G(contains: ["↑↓ to navigate"]),
                              ]),
                          ])),
        AgentRule(id: "live_blocked_form_named_session", state: .blocked, priority: 980,
                  visibleBlocker: true,
                  gate: G(regex: [#"(?i)(?:^|\n)[ \t]*enter\s+to\s+(?:confirm|select\s+·\s+(?:(?:tab/arrow|arrow)\s+keys|arrows|↑/↓|↑↓)\s+to\s+navigate)\s+·\s+esc\s+to\s+cancel[ \t]*\n(?:[ \t]*\n)*[ \t]*─{3,}[^\n]*(?:\n(?:[ \t]*\n)*[ \t]+\d+ tasks? \(\d+ done, (?:\d+ in progress, )?\d+ open\)(?:\n[ \t]+[◻◼✔][ \t]+[^\n]+)+(?:\n[ \t]+…[ \t]+\+\d+[ \t]+pending)?)?(?:\n[ \t]*)*\z"#])),
        AgentRule(id: "dynamic_workflow_prompt", state: .blocked, priority: 980, visibleBlocker: true,
                  gate: G(contains: ["run a dynamic workflow?", "esc to cancel"])),
        AgentRule(id: "mcp_elicitation_prompt", state: .blocked, priority: 980, visibleBlocker: true,
                  gate: G(contains: ["esc to cancel"],
                          lineRegex: [#"(?i)^\s*MCP server ["\x{201C}].+["\x{201D}] requests your input\s*$"#],
                          all: [G(any: [
                              G(lineRegex: [#"^\s*\x{276F}?\s*Accept\b"#]),
                              G(lineRegex: [#"^\s*\x{276F}?\s*Decline\b"#]),
                          ])])),
        AgentRule(id: "live_prompt_box", state: .idle, priority: 950, region: .promptBoxBody,
                  visibleIdle: true,
                  gate: G(lineRegex: [#"^\s*❯"#],
                          not: [
                              G(contains: ["enter to select"]),
                              G(contains: ["esc to cancel"]),
                              G(contains: ["tab/arrow keys"]),
                              G(contains: ["arrow keys to navigate"]),
                              G(contains: ["↑/↓ to navigate"]),
                          ])),
        AgentRule(id: "model_picker_menu", state: .unknown, priority: 900, skipUpdate: true,
                  gate: G(contains: ["select model", "enter to set as default", "esc to cancel"],
                          not: [
                              G(contains: ["do you want to proceed?"]),
                              G(contains: ["enter to select"]),
                          ])),
        AgentRule(id: "bash_permission_prompt", state: .blocked, priority: 850, visibleBlocker: true,
                  gate: G(contains: ["do you want to proceed?"],
                          all: [G(any: [
                              G(lineRegex: [#"(?i)^\s*❯?\s*yes\b"#]),
                              G(lineRegex: [#"(?i)^\s*❯?\s*1\.\s*yes\b"#]),
                              G(lineRegex: [#"(?i)^\s*❯?\s*2\.\s*yes\b"#]),
                              G(lineRegex: [#"(?i)^\s*❯?\s*2\.\s*no\b"#]),
                              G(lineRegex: [#"(?i)^\s*❯?\s*3\.\s*no\b"#]),
                          ])],
                          any: [
                              G(contains: ["bash command"]),
                              G(contains: ["bash("]),
                              G(contains: ["contains expansion"]),
                              G(contains: ["tab to amend"]),
                              G(contains: ["ctrl+e to explain"]),
                          ])),
        AgentRule(id: "generic_permission_prompt", state: .blocked, priority: 840,
                  region: .afterLastHorizontalRule, visibleBlocker: true,
                  gate: G(contains: ["do you want to proceed?", "esc to cancel"],
                          all: [G(any: [
                              G(lineRegex: [#"(?i)^\s*❯?\s*1\.\s*yes\b"#]),
                              G(lineRegex: [#"(?i)^\s*2\.\s*yes\b"#]),
                              G(lineRegex: [#"(?i)^\s*2\.\s*no\b"#]),
                              G(lineRegex: [#"(?i)^\s*3\.\s*no\b"#]),
                          ])])),
        AgentRule(id: "legacy_no_prompt_blocker", state: .blocked, priority: 300,
                  gate: G(any: [
                      G(contains: ["do you want to"], any: [G(contains: ["yes"]), G(contains: ["❯"])]),
                      G(contains: ["would you like to"], any: [G(contains: ["yes"]), G(contains: ["❯"])]),
                      G(contains: ["waiting for permission"]),
                      G(contains: ["do you want to allow this connection?"]),
                      G(contains: ["tab to amend"]),
                      G(contains: ["ctrl+e to explain"]),
                      G(contains: ["do you want to proceed?", "esc to cancel"]),
                      G(contains: ["review your answers"]),
                      G(contains: ["skip interview and plan immediately"]),
                  ], not: [
                      G(regex: [#"(?m)^\s*❯\s*$"#]),
                  ])),
        AgentRule(id: "osc_title_idle", state: .idle, priority: 250, region: .oscTitle,
                  visibleIdle: true,
                  gate: G(regex: [#"^\x{2733} "#])),
    ]

    // MARK: codex.toml 2026.10.11.1

    static let codex: [AgentRule] = [
        AgentRule(id: "osc_title_blocked", state: .blocked, priority: 1100, region: .oscTitle,
                  visibleBlocker: true,
                  gate: G(contains: ["Action Required"])),
        AgentRule(id: "osc_title_working", state: .working, priority: 1050, region: .oscTitle,
                  gate: G(regex: [#"(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)"#])),
        AgentRule(id: "transcript_viewer", state: .unknown, priority: 1000,
                  region: .afterLastPromptMarker, skipUpdate: true,
                  gate: G(contains: ["↑/↓ to scroll", "pgup/pgdn to", "home/end to jump", "q to quit"],
                          any: [
                              G(contains: ["esc to edit prev"]),
                              G(contains: ["esc/← to edit prev"]),
                          ])),
        AgentRule(id: "trust_directory", state: .blocked, priority: 950,
                  region: .topNonEmptyLines(20), visibleBlocker: true,
                  gate: G(all: [
                      G(any: [
                          G(regex: [#"\A> You are in [^\r\n]+(?:\r?\n|$)"#]),
                          G(contains: ["Folder access"]),
                      ]),
                      G(any: [
                          G(regex: [#"(?s)Do\s+you\s+trust\s+the\s+contents\s+of\s+this\s+directory\?"#]),
                          G(all: [
                              G(contains: ["Trust this folder?", "Codex can read, edit, and run files here"]),
                              G(any: [
                                  G(contains: ["Trust and continue"]),
                                  G(contains: ["enter continue"]),
                              ]),
                          ]),
                      ]),
                  ])),
        AgentRule(id: "startup_update", state: .blocked, priority: 950,
                  region: .bottomNonEmptyLines(20), visibleBlocker: true,
                  gate: G(any: [
                      G(all: [
                          G(contains: ["Update available!", "Update now"]),
                          G(regex: [#"Skip\s+until\s+next\s+version"#, #"Press enter to continue\s*\z"#]),
                      ]),
                      G(all: [
                          G(regex: [#"(?m)^\s*Update\s+available\s+·"#]),
                          G(regex: [#"enter\s+continue\s+·\s+esc\s+skip\s*\z"#]),
                      ]),
                  ])),
        AgentRule(id: "live_strong_blocker", state: .blocked, priority: 900,
                  region: .afterLastPromptMarker, visibleBlocker: true,
                  gate: G(any: [
                      G(contains: ["press enter to confirm or esc to cancel"]),
                      G(contains: ["enter to submit answer"]),
                      G(contains: ["enter to submit all"]),
                      G(contains: ["allow command?"]),
                      G(contains: ["All Results", "Filesystem Only", "Plugins"]),
                  ])),
        AgentRule(id: "weak_blocker", state: .blocked, priority: 600,
                  region: .wholeRecentWithoutCurrentPromptMarker,
                  gate: G(any: [
                      G(contains: ["[y/n]"]),
                      G(contains: ["yes (y)"]),
                      G(contains: ["do you want to"], any: [G(contains: ["yes"]), G(contains: ["❯"])]),
                      G(contains: ["would you like to"], any: [G(contains: ["yes"]), G(contains: ["❯"])]),
                  ], not: [
                      G(regex: [#"(?m)^›[⠁⠂⠄⠈⠐⠠⡀⢀][^\n]*(?:\n(?:[^•■✗✓\n][^\n]*)?)*\z"#]),
                  ])),
        AgentRule(id: "screen_working_fallback", state: .working, priority: 500,
                  region: .beforeCurrentPromptMarker,
                  gate: G(regex: [#"(?m)^(?:[•◦][ \t]+)?[^\s›•◦■✗✓─][^\r\n]* \((?:[0-9]+[hm] )*[0-9]+s(?: • [^\r\n]+? to interrupt)?\)(?: · [^\r\n]*)?(?:\r?\n(?:[^•◦›■✗✓─\r\n][^\r\n]*|•[ \t]+(?:Queued\s+follow-up\s+inputs|Messages\s+to\s+be\s+submitted\s+after\s+next\s+tool\s+call(?:\s+\(press\s+[^\r\n]+?\s+to\s+interrupt\s+and\s+send\s+immediately\))?|Messages\s+to\s+be\s+submitted\s+at\s+end\s+of\s+turn)|›[⠁⠂⠄⠈⠐⠠⡀⢀][^\r\n]*)?)*\s*\z"#],
                          any: [G(contains: [" to interrupt)"]), G(contains: ["s)"])],
                          not: [G(lineRegex: [#"^(?:[•◦][ \t]+)?Reconnect failed — check the endpoint, then relaunch \([0-9hms ]+\)$"#])])),
        AgentRule(id: "osc_title_idle", state: .idle, priority: 100, region: .oscTitle,
                  visibleIdle: true,
                  gate: G(regex: [#"\S"#],
                          not: [
                              G(regex: [#"(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)"#]),
                              G(contains: ["Action Required"]),
                          ])),
    ]

    // MARK: gemini.toml 2026.06.10.1

    static let gemini: [AgentRule] = [
        AgentRule(id: "apply_or_allow_change", state: .blocked, priority: 300, visibleBlocker: true,
                  gate: G(any: [
                      G(contains: ["│ Apply this change"]),
                      G(contains: ["│ Allow execution"]),
                      G(all: [
                          G(contains: ["yes"]),
                          G(any: [
                              G(contains: ["waiting for user confirmation"]),
                              G(contains: ["│ Do you want to proceed"]),
                              G(contains: ["do you want to proceed?"]),
                          ]),
                      ]),
                      G(lineRegex: [#"(?i)^\s*❯.*(yes|allow)"#]),
                  ])),
        AgentRule(id: "esc_cancel_working", state: .working, priority: 100,
                  gate: G(contains: ["esc to cancel"])),
    ]
}

/// Compiled patterns, built once per process. NSRegularExpression is
/// thread-safe for matching; the cache's own map is lock-guarded.
enum AgentRegexCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var compiled: [String: NSRegularExpression?] = [:]

    static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = compiled[pattern] { return hit }
        let made = try? NSRegularExpression(pattern: pattern)
        compiled[pattern] = made
        return made
    }
}
