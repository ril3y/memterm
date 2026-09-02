import AppKit
import MemtermExtensionKit

// MemtermClaudeBrowser — the FIRST kit consumer (stage 3 of the extension
// architecture, decision doc 496a85fe; the Claude-native bet, both halves):
//
//   1. The Claude Sessions browser: every session ever run, straight from
//      host.claude.projects()/sessions() — grouped by project (REAL cwd from
//      jsonl content, never slug-inversion), newest first, searchable, with
//      per-session "Resume in New Tab" (openTab + stageResume: the standard
//      consent-gated ⌘R offer appears in the new tab — this extension never
//      sees a command string) and "Reveal in Finder" (performed by the APP;
//      no path ever crosses the kit).
//   2. Needs-attention on live tabs: claude state (working / needs-input /
//      done, resolved by the core-side parser) feeds host.ui.setBadge into
//      the EXISTING tab activity-indicator slot. No new chrome.
//
// THE FIREWALL PROVES ITSELF HERE: this target depends on MemtermExtensionKit
// alone (see Package.swift; scripts/check-extension-firewall.sh). It cannot
// import MemtermCore, StateStore, PaneView, or the app — the consent gesture,
// denylist, and keystroke path are structurally out of reach.

// MARK: - Pure model (headlessly tested in MemtermClaudeBrowserTests)

public enum ClaudeBrowserModel {

    /// One rendered project group: the kit project, its honest display path
    /// (newest session's cwd — the slug only when no session carries a cwd),
    /// and its sessions, newest first as the host returns them.
    public struct ProjectGroup: Equatable {
        public let project: ClaudeProject
        public let displayPath: String
        public let sessions: [ClaudeSessionInfo]

        public init(project: ClaudeProject, displayPath: String,
                    sessions: [ClaudeSessionInfo]) {
            self.project = project
            self.displayPath = displayPath
            self.sessions = sessions
        }
    }

    /// Builds groups from the host surface. `fetchSessions` is
    /// host.claude.sessions in production, a fixture in tests. Projects with
    /// zero sessions are dropped (nothing to browse); host ordering (most
    /// recently active first) is preserved on both levels.
    public static func groups(projects: [ClaudeProject],
                              fetchSessions: (ClaudeProject) -> [ClaudeSessionInfo])
        -> [ProjectGroup] {
        projects.compactMap { project in
            let sessions = fetchSessions(project)
            guard !sessions.isEmpty else { return nil }
            // Real cwd from jsonl content, NEVER slug-inversion (the slug
            // encoding is lossy). Newest session with a cwd wins.
            let path = sessions.first(where: { $0.cwd?.isEmpty == false })?.cwd
                ?? project.slug
            return ProjectGroup(project: project, displayPath: path,
                                sessions: sessions)
        }
    }

    /// Search: case-insensitive. A query matching the project (display path
    /// or slug) keeps the whole group; otherwise the group narrows to the
    /// sessions whose id / last prompt / cwd match. Empty groups drop out.
    public static func filter(_ groups: [ProjectGroup], query: String) -> [ProjectGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            if group.displayPath.localizedCaseInsensitiveContains(needle)
                || group.project.slug.localizedCaseInsensitiveContains(needle) {
                return group
            }
            let hits = group.sessions.filter { session in
                session.id.raw.localizedCaseInsensitiveContains(needle)
                    || session.lastPrompt?.localizedCaseInsensitiveContains(needle) == true
                    || session.cwd?.localizedCaseInsensitiveContains(needle) == true
            }
            guard !hits.isEmpty else { return nil }
            return ProjectGroup(project: group.project,
                                displayPath: group.displayPath, sessions: hits)
        }
    }

    /// The session's badge-relevant state, from the core-side parser's typed
    /// result: working (live, jsonl flowing) / needs-input (live but quiet) /
    /// done (no live process).
    public static func attentionState(for session: ClaudeSessionInfo) -> AttentionState {
        guard session.isLive else { return .none }         // done
        return session.needsAttention ? .attention : .active
    }
}

/// Badge planning: which AttentionState each claude-hosting tab should show.
/// Pure — the extension applies the plan (diffed) through host.ui.setBadge.
public enum ClaudeBadgePlanner {

    static func rank(_ state: AttentionState) -> Int {
        switch state {
        case .none: return 0
        case .active: return 1
        case .attention: return 2
        }
    }

    /// Every tab in `tabSessions` gets an entry — .none for a finished
    /// session, so a done claude CLEARS its badge instead of leaving a stale
    /// spinner. A tab hosting several sessions (splits) shows the strongest
    /// state (attention > active > none). A session missing from `info`
    /// (project vanished between scans) plans .none.
    public static func plan(tabSessions: [ClaudeTabSession],
                            info: [ClaudeSessionID: ClaudeSessionInfo])
        -> [TabRef: AttentionState] {
        var plan: [TabRef: AttentionState] = [:]
        for binding in tabSessions {
            let state = info[binding.id].map(ClaudeBrowserModel.attentionState) ?? .none
            if let existing = plan[binding.tab], rank(existing) >= rank(state) {
                continue
            }
            plan[binding.tab] = state
        }
        return plan
    }
}

// MARK: - The extension

public final class ClaudeBrowserExtension: MemtermExtension {
    public static let extensionId = "claude-browser"
    public static let panelId = "claude-browser.sessions"

    private var host: MemtermHost?
    private var subscriptions: [Subscription] = []
    private var badgeTimer: Timer?
    /// Last applied badge per tab — setBadge only fires on change, and
    /// vanished tabs get an explicit clear.
    private var appliedBadges: [TabRef: AttentionState] = [:]
    private weak var panel: ClaudeSessionsPanelController?

    public init() {}

    public func activate(host: MemtermHost) {
        self.host = host
        host.ui.registerPanel(Self.panelId, "Claude Sessions", "cmd+shift+c") {
            [weak self] in
            let controller = ClaudeSessionsPanelController(host: host)
            self?.panel = controller
            return controller
        }
        subscriptions.append(host.events.subscribe(.claudeSessionsChanged) {
            [weak self] _ in self?.refreshNow()
        })
        subscriptions.append(host.events.subscribe(.tabClosed) { [weak self] payload in
            guard let tab = payload.tab else { return }
            self?.appliedBadges[tab] = nil  // gone with the tab; never re-badged
        })
        // needs-attention flips on QUIET (no ~/.claude write to fire the
        // FSEvents subscription), so a modest timer re-plans badges; it
        // re-scans only the projects of tabs actually hosting claude.
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshBadges()
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        badgeTimer = timer
    }

    public func deactivate() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
        badgeTimer?.invalidate()
        badgeTimer = nil
        host = nil
    }

    /// Event/timer funnel; also the probe seam (probes drive refresh
    /// synchronously instead of waiting on FSEvents latency).
    public func refreshNow() {
        refreshBadges()
        panel?.reload()
    }

    private func refreshBadges() {
        guard let host else { return }
        let tabSessions = host.claude.tabSessions()
        // Scope session lookups to the slugs the live tabs actually name.
        var info: [ClaudeSessionID: ClaudeSessionInfo] = [:]
        let slugs = Set(tabSessions.compactMap(\.projectSlug))
        for slug in slugs {
            let project = ClaudeProject(slug: slug, sessionCount: 0, lastActivity: nil)
            for session in host.claude.sessions(project) {
                info[session.id] = session
            }
        }
        let plan = ClaudeBadgePlanner.plan(tabSessions: tabSessions, info: info)
        // Tabs that no longer host claude: clear their badge once.
        for (tab, state) in appliedBadges where plan[tab] == nil && state != .none {
            host.ui.setBadge(tab, .none)
        }
        for (tab, state) in plan where appliedBadges[tab] != state {
            host.ui.setBadge(tab, state)
        }
        appliedBadges = plan
    }

    // MARK: Probe seams (MEMTERM_UI_PROBE legs; harmless in production)

    public var probePanel: ClaudeSessionsPanelController? { panel }
    public var probeAppliedBadges: [TabRef: AttentionState] { appliedBadges }
}
