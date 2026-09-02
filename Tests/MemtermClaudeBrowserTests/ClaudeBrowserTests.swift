import AppKit
import XCTest
import MemtermExtensionKit
@testable import MemtermClaudeBrowser

// L1/L2 for the Claude-browser extension: the pure model (grouping, honest
// display paths, search filtering, badge planning) plus the extension's
// host-call traffic — badge diffing, event wiring, and the resume flow's
// openTab-then-stageResume order — against a recording mock Host. Headless;
// the presented panel is L4's job (probe legs claude-browser-*).

final class ClaudeBrowserTests: XCTestCase {

    private func session(_ id: String, slug: String = "p",
                         age: TimeInterval = 0, live: Bool = false,
                         attention: Bool = false, prompt: String? = nil,
                         cwd: String? = nil) -> ClaudeSessionInfo {
        ClaudeSessionInfo(id: ClaudeSessionID(raw: id), projectSlug: slug,
                          lastActivity: Date(timeIntervalSinceNow: -age),
                          isLive: live, needsAttention: attention,
                          lastPrompt: prompt, cwd: cwd, claudeVersion: nil)
    }

    // MARK: - Model: grouping

    func testGroupsUseRealCwdNeverSlugInversionAndDropEmptyProjects() {
        let projects = [ClaudeProject(slug: "-tmp-alpha", sessionCount: 2, lastActivity: Date()),
                        ClaudeProject(slug: "-tmp-empty", sessionCount: 0, lastActivity: nil)]
        let groups = ClaudeBrowserModel.groups(projects: projects) { project in
            guard project.slug == "-tmp-alpha" else { return [] }
            // Newest session carries no cwd; the next one does — the newest
            // HONEST path wins, and the lossy slug is never inverted.
            return [session("aaaa-1", slug: project.slug, age: 10),
                    session("bbbb-2", slug: project.slug, age: 20, cwd: "/tmp/alpha")]
        }
        XCTAssertEqual(groups.count, 1, "projects with no sessions do not render")
        XCTAssertEqual(groups[0].displayPath, "/tmp/alpha")
        XCTAssertEqual(groups[0].sessions.map { $0.id.raw }, ["aaaa-1", "bbbb-2"])
    }

    func testGroupFallsBackToSlugWhenNoSessionCarriesCwd() {
        let projects = [ClaudeProject(slug: "-x", sessionCount: 1, lastActivity: nil)]
        let groups = ClaudeBrowserModel.groups(projects: projects) { _ in
            [session("cccc-3", slug: "-x")]
        }
        XCTAssertEqual(groups[0].displayPath, "-x",
                       "no cwd anywhere → the slug displays as-is (never inverted into a path)")
    }

    // MARK: - Model: search

    func testFilterMatchesProjectPathKeepingWholeGroup() {
        let group = ClaudeBrowserModel.ProjectGroup(
            project: ClaudeProject(slug: "-tmp-alpha", sessionCount: 2, lastActivity: nil),
            displayPath: "/tmp/alpha",
            sessions: [session("aaaa-1", prompt: "fix tests"), session("bbbb-2")])
        let hit = ClaudeBrowserModel.filter([group], query: "ALPHA")
        XCTAssertEqual(hit.count, 1)
        XCTAssertEqual(hit[0].sessions.count, 2, "project match keeps every session")
        XCTAssertTrue(ClaudeBrowserModel.filter([group], query: "zebra").isEmpty)
    }

    func testFilterNarrowsToMatchingSessionsByPromptOrId() {
        let group = ClaudeBrowserModel.ProjectGroup(
            project: ClaudeProject(slug: "-p", sessionCount: 2, lastActivity: nil),
            displayPath: "/p",
            sessions: [session("aaaa-1", prompt: "fix the flaky bench"),
                       session("bbbb-2", prompt: "write docs")])
        let byPrompt = ClaudeBrowserModel.filter([group], query: "flaky")
        XCTAssertEqual(byPrompt[0].sessions.map { $0.id.raw }, ["aaaa-1"])
        let byId = ClaudeBrowserModel.filter([group], query: "bbbb")
        XCTAssertEqual(byId[0].sessions.map { $0.id.raw }, ["bbbb-2"])
        XCTAssertEqual(ClaudeBrowserModel.filter([group], query: "  ").count, 1,
                       "whitespace-only query = no filter")
    }

    // MARK: - Model: attention state (working / needs-input / done)

    func testAttentionStateMapping() {
        XCTAssertEqual(ClaudeBrowserModel.attentionState(
            for: session("a", live: true, attention: false)), .active, "working")
        XCTAssertEqual(ClaudeBrowserModel.attentionState(
            for: session("a", live: true, attention: true)), .attention, "needs input")
        XCTAssertEqual(ClaudeBrowserModel.attentionState(
            for: session("a", live: false)), AttentionState.none, "done clears")
    }

    // MARK: - Badge planning

    func testBadgePlanStrongestStatePerTabAndExplicitClears() {
        let tab1 = TabRef(tabId: "t1"), tab2 = TabRef(tabId: "t2")
        let working = session("work", live: true)
        let waiting = session("wait", live: true, attention: true)
        let done = session("done", live: false)
        let plan = ClaudeBadgePlanner.plan(
            tabSessions: [
                ClaudeTabSession(tab: tab1, id: working.id, projectSlug: "p"),
                ClaudeTabSession(tab: tab1, id: waiting.id, projectSlug: "p"),
                ClaudeTabSession(tab: tab2, id: done.id, projectSlug: "p"),
            ],
            info: [working.id: working, waiting.id: waiting, done.id: done])
        XCTAssertEqual(plan[tab1], .attention,
                       "a split tab hosting working+waiting shows the strongest state")
        XCTAssertEqual(plan[tab2], AttentionState.none,
                       "a finished session plans an explicit clear, not absence")
    }

    func testBadgePlanUnknownSessionPlansClear() {
        let tab = TabRef(tabId: "t")
        let plan = ClaudeBadgePlanner.plan(
            tabSessions: [ClaudeTabSession(tab: tab, id: ClaudeSessionID(raw: "gone"),
                                           projectSlug: nil)],
            info: [:])
        XCTAssertEqual(plan[tab], AttentionState.none)
    }

    // MARK: - Extension against a recording mock host

    private final class MockHost {
        var calls: [String] = []
        var badges: [(tab: String, state: AttentionState)] = []
        var handlers: [HostEvent: (HostEventPayload) -> Void] = [:]
        var tabSessions: [ClaudeTabSession] = []
        var sessionsBySlug: [String: [ClaudeSessionInfo]] = [:]
        var projects: [ClaudeProject] = []
        var registeredPanels: [(id: String, title: String, shortcut: String?)] = []
        var openTabResult: TabRef? = TabRef(tabId: "new-tab")
        var stageResumeResult = true

        lazy var host = MemtermHost(
            archive: ArchiveHost(query: { _ in [] }, search: { _ in [] },
                                 frozenScrollback: { _ in nil }, requestForget: { _ in },
                                 revealFiles: { _ in }),
            claude: ClaudeHost(
                projects: { [unowned self] in calls.append("projects"); return projects },
                sessions: { [unowned self] project in
                    calls.append("sessions \(project.slug)")
                    return sessionsBySlug[project.slug] ?? []
                },
                tabSessions: { [unowned self] in
                    calls.append("tabSessions"); return tabSessions
                },
                revealSession: { [unowned self] id, slug in
                    calls.append("reveal \(id.raw) \(slug)")
                },
                rootDisplayPath: { "~/.claude/projects" }),
            workspace: WorkspaceHost(
                openTab: { [unowned self] cwd, _ in
                    calls.append("openTab \(cwd?.path ?? "-")")
                    return openTabResult
                },
                reopenGhost: { _, _ in nil },
                parkedWorkspaces: { [] },
                openWorkspace: { _ in false },
                stageResume: { [unowned self] id, tab in
                    calls.append("stageResume \(id.raw) on=\(tab.tabId)")
                    return stageResumeResult
                }),
            ui: UIHost(
                registerPanel: { [unowned self] id, title, shortcut, _ in
                    registeredPanels.append((id, title, shortcut))
                },
                setBadge: { [unowned self] tab, state in
                    badges.append((tab.tabId, state))
                },
                addTabContextMenuItem: { _, _, _ in },
                settingsSection: { _ in }),
            events: EventsHost(subscribe: { [unowned self] event, handler in
                handlers[event] = handler
                return Subscription(onCancel: {})
            }))
    }

    func testActivateRegistersPanelAndSubscribesBothEvents() {
        let mock = MockHost()
        let ext = ClaudeBrowserExtension()
        ext.activate(host: mock.host)
        XCTAssertEqual(mock.registeredPanels.map(\.id), ["claude-browser.sessions"])
        XCTAssertEqual(mock.registeredPanels[0].title, "Claude Sessions")
        XCTAssertEqual(mock.registeredPanels[0].shortcut, "cmd+shift+c")
        XCTAssertNotNil(mock.handlers[.claudeSessionsChanged])
        XCTAssertNotNil(mock.handlers[.tabClosed])
        ext.deactivate()
    }

    func testBadgeRefreshSetsDiffsAndClearsThroughSetBadge() {
        let mock = MockHost()
        let waiting = session("wait-1", slug: "p", live: true, attention: true)
        mock.tabSessions = [ClaudeTabSession(tab: TabRef(tabId: "t1"),
                                             id: waiting.id, projectSlug: "p")]
        mock.sessionsBySlug["p"] = [waiting]
        let ext = ClaudeBrowserExtension()
        ext.activate(host: mock.host)

        mock.handlers[.claudeSessionsChanged]?(
            HostEventPayload(event: .claudeSessionsChanged, tab: nil))
        XCTAssertEqual(mock.badges.map(\.tab), ["t1"])
        XCTAssertEqual(mock.badges.map(\.state), [.attention])

        // Same state again: NO duplicate setBadge (diffed application).
        mock.handlers[.claudeSessionsChanged]?(
            HostEventPayload(event: .claudeSessionsChanged, tab: nil))
        XCTAssertEqual(mock.badges.count, 1, "unchanged plan re-applies nothing")

        // The claude exits (tab no longer hosts one): explicit clear.
        mock.tabSessions = []
        mock.handlers[.claudeSessionsChanged]?(
            HostEventPayload(event: .claudeSessionsChanged, tab: nil))
        XCTAssertEqual(mock.badges.count, 2)
        XCTAssertEqual(mock.badges.last?.state, AttentionState.none)
        ext.deactivate()
    }

    func testTabClosedDropsTheBadgeRecordWithoutSetBadgeOnADeadTab() {
        let mock = MockHost()
        let working = session("work-1", slug: "p", live: true)
        let tab = TabRef(tabId: "t1")
        mock.tabSessions = [ClaudeTabSession(tab: tab, id: working.id, projectSlug: "p")]
        mock.sessionsBySlug["p"] = [working]
        let ext = ClaudeBrowserExtension()
        ext.activate(host: mock.host)
        mock.handlers[.claudeSessionsChanged]?(
            HostEventPayload(event: .claudeSessionsChanged, tab: nil))
        XCTAssertEqual(mock.badges.count, 1)

        mock.handlers[.tabClosed]?(HostEventPayload(event: .tabClosed, tab: tab))
        XCTAssertEqual(ext.probeAppliedBadges[tab], nil, "record dropped")
        mock.tabSessions = []
        mock.handlers[.claudeSessionsChanged]?(
            HostEventPayload(event: .claudeSessionsChanged, tab: nil))
        XCTAssertEqual(mock.badges.count, 1,
                       "no clear is sent for a tab that already closed")
        ext.deactivate()
    }

    func testResumeFlowOpensTabThenStagesResumeInThatOrder() {
        let mock = MockHost()
        let info = session("aaaa-uuid", slug: "p", cwd: "/tmp/proj")
        let panel = ClaudeSessionsPanelController(host: mock.host)
        let node = ClaudeSessionsPanelController.SessionNode(info, slug: "p")
        XCTAssertTrue(panel.resumeSession(node))
        XCTAssertEqual(mock.calls, ["openTab /tmp/proj",
                                    "stageResume aaaa-uuid on=new-tab"],
                       "openTab first, stageResume into the returned tab — no other host traffic")
    }

    func testResumeFlowFailsClosedWhenNoTabOpens() {
        let mock = MockHost()
        mock.openTabResult = nil
        let panel = ClaudeSessionsPanelController(host: mock.host)
        let node = ClaudeSessionsPanelController.SessionNode(
            session("bbbb-uuid", slug: "p"), slug: "p")
        XCTAssertFalse(panel.resumeSession(node))
        XCTAssertEqual(mock.calls, ["openTab -"],
                       "no tab → stageResume is never attempted")
    }
}
