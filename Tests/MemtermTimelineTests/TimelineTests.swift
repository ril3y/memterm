import AppKit
import XCTest
import MemtermExtensionKit
@testable import MemtermTimeline

// L1 model truth for the timeline extension: day grouping, reboot seams,
// parked-workspace cards, duration/label formatting — pure functions against
// fixed clocks and a fixed calendar (bug-4 discipline: no Date() in
// assertions). Plus the extension's host-call traffic against a recording
// mock — headless, no app, no panel windows.

final class TimelineModelTests: XCTestCase {

    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Tue Sep 2 2026 12:00:00 UTC — a fixed "now".
    private let now = Date(timeIntervalSince1970: 1_788_350_400)

    private func card(_ id: String, closedAgo: TimeInterval?, boot: String? = "boot-a",
                      opened: TimeInterval? = nil, workspace: String = "Work",
                      kind: SessionKind = .shell,
                      claudeId: String? = nil) -> SessionCard {
        let closedAt = closedAgo.map { now.addingTimeInterval(-$0) }
        return SessionCard(id: SessionID(raw: id), title: "t-\(id)",
                           workspaceName: workspace, workspaceColorHex: "#ff6b35",
                           cwd: "/tmp/\(id)", kind: kind,
                           openedAt: opened.map { now.addingTimeInterval(-$0) },
                           closedAt: closedAt, closeReason: .userClose,
                           bootStamp: boot,
                           claudeSessionId: claudeId.map(ClaudeSessionID.init(raw:)),
                           preview: "cmd-\(id)")
    }

    // MARK: Day labels

    func testDayLabelsTodayYesterdayAndDated() {
        XCTAssertEqual(TimelineModel.dayLabel(for: now, now: now, calendar: calendar),
                       "Today")
        XCTAssertEqual(TimelineModel.dayLabel(for: now.addingTimeInterval(-86_400),
                                              now: now, calendar: calendar),
                       "Yesterday")
        // Aug 25 2026 is a Tuesday the week before — dated, no year (same year).
        let older = now.addingTimeInterval(-8 * 86_400)
        let label = TimelineModel.dayLabel(for: older, now: now, calendar: calendar)
        XCTAssertTrue(label.contains("Aug"), "dated label names the month: \(label)")
        XCTAssertFalse(label.contains("2026"), "same-year label omits the year: \(label)")
        // A previous-year date keeps the year — long retention stays unambiguous.
        let lastYear = now.addingTimeInterval(-400 * 86_400)
        XCTAssertTrue(TimelineModel.dayLabel(for: lastYear, now: now,
                                             calendar: calendar).contains("2025"))
    }

    // MARK: Grouping

    func testRowsGroupByDayNewestFirstWithHeaders() {
        let cards = [card("3", closedAgo: 60), card("2", closedAgo: 3600),
                     card("1", closedAgo: 86_400 + 60)]
        let rows = TimelineModel.rows(cards: cards, parked: [], now: now,
                                      calendar: calendar)
        XCTAssertEqual(rows, [
            .header("Today"), .session(cards[0]), .session(cards[1]),
            .header("Yesterday"), .session(cards[2]),
        ], "one header per day boundary, host order preserved")
    }

    func testRebootBreakAppearsOnlyOnSameDayBootChange() {
        let beforeReboot = card("old", closedAgo: 7200, boot: "boot-old")
        let cards = [card("new", closedAgo: 60, boot: "boot-new"), beforeReboot,
                     card("prev", closedAgo: 86_400 + 60, boot: "boot-ancient")]
        let rows = TimelineModel.rows(cards: cards, parked: [], now: now,
                                      calendar: calendar)
        XCTAssertEqual(rows, [
            .header("Today"), .session(cards[0]), .rebootBreak, .session(cards[1]),
            .header("Yesterday"), .session(cards[2]),
        ], "a boot seam inside one day gets the break; a day boundary already separates")
    }

    func testNoRebootBreakWhenAStampIsUnknown() {
        let cards = [card("a", closedAgo: 60, boot: nil),
                     card("b", closedAgo: 120, boot: "boot-a")]
        let rows = TimelineModel.rows(cards: cards, parked: [], now: now,
                                      calendar: calendar)
        XCTAssertFalse(rows.contains(.rebootBreak),
                       "an unknown stamp never fabricates a reboot")
    }

    func testUnknownCloseDateLandsUnderEarlier() {
        let cards = [card("a", closedAgo: 60), card("x", closedAgo: nil)]
        let rows = TimelineModel.rows(cards: cards, parked: [], now: now,
                                      calendar: calendar)
        XCTAssertEqual(rows, [.header("Today"), .session(cards[0]),
                              .header("Earlier"), .session(cards[1])])
    }

    func testParkedWorkspacesLeadInTheirOwnSection() {
        let parked = [WorkspaceCard(id: WorkspaceID(raw: "w1"), name: "Client",
                                    colorHex: "#0a84ff")]
        let cards = [card("a", closedAgo: 60)]
        let rows = TimelineModel.rows(cards: cards, parked: parked, now: now,
                                      calendar: calendar)
        XCTAssertEqual(rows, [
            .header("Parked Workspaces"), .workspace(parked[0]),
            .header("Today"), .session(cards[0]),
        ], "FR-54: a parked workspace is one reopenable card, leading the list")
        XCTAssertEqual(TimelineModel.rows(cards: [], parked: [], now: now,
                                          calendar: calendar), [],
                       "nothing archived, nothing parked → no rows (empty state)")
    }

    // MARK: Labels

    func testDurationLabels() {
        func label(_ span: TimeInterval?) -> String? {
            TimelineModel.durationLabel(
                openedAt: span.map { now.addingTimeInterval(-$0) }, closedAt: now)
        }
        XCTAssertNil(label(nil), "unknown open time → no duration")
        XCTAssertNil(label(0), "non-positive span → no duration")
        XCTAssertEqual(label(8), "8s")
        XCTAssertEqual(label(300), "5m")
        XCTAssertEqual(label(4320), "1h 12m")
        XCTAssertEqual(label(7200), "2h")
        XCTAssertEqual(label(2 * 86_400 + 3 * 3600), "2d 3h")
        XCTAssertNil(TimelineModel.durationLabel(openedAt: now, closedAt: nil))
    }

    /// The "in 0s" screenshot bug: whole-second close stamps can sit a hair
    /// AHEAD of the render clock; the fresh end must never read future tense.
    func testRecentAgeLabelAbsorbsSkewAndFreshCloses() {
        XCTAssertEqual(TimelineModel.recentAgeLabel(
            closedAt: now.addingTimeInterval(0.5), now: now), "just now",
            "sub-second future skew must render as just now, never 'in 0s'")
        XCTAssertEqual(TimelineModel.recentAgeLabel(closedAt: now, now: now), "just now")
        XCTAssertEqual(TimelineModel.recentAgeLabel(
            closedAt: now.addingTimeInterval(-59), now: now), "just now")
        XCTAssertNil(TimelineModel.recentAgeLabel(
            closedAt: now.addingTimeInterval(-61), now: now),
            "older cards defer to the relative formatter's past tense")
    }

    func testCloseReasonLabelsStaySubtle() {
        XCTAssertEqual(TimelineModel.closeReasonLabel(.userClose), "closed")
        XCTAssertEqual(TimelineModel.closeReasonLabel(.shellExited), "exited")
        XCTAssertNil(TimelineModel.closeReasonLabel(.other),
                     "an unknown reason renders nothing rather than guessing")
    }
}

// MARK: - Extension traffic against a recording mock

final class TimelineExtensionTests: XCTestCase {

    private final class MockHost {
        var registeredPanels: [(id: String, title: String, shortcut: String?)] = []
        var handlers: [HostEvent: (HostEventPayload) -> Void] = [:]
        var cancelled = 0

        lazy var host = MemtermHost(
            archive: ArchiveHost(query: { _ in [] }, search: { _ in [] },
                                 frozenScrollback: { _ in nil }, requestForget: { _ in },
                                 revealFiles: { _ in }),
            claude: ClaudeHost(projects: { [] }, sessions: { _ in [] },
                               tabSessions: { [] }, revealSession: { _, _ in },
                               rootDisplayPath: { "~" }),
            workspace: WorkspaceHost(openTab: { _, _ in nil },
                                     reopenGhost: { _, _ in nil },
                                     parkedWorkspaces: { [] },
                                     openWorkspace: { _ in false },
                                     stageResume: { _, _ in false }),
            ui: UIHost(registerPanel: { [unowned self] id, title, shortcut, _ in
                           registeredPanels.append((id, title, shortcut))
                       },
                       setBadge: { _, _ in }, addTabContextMenuItem: { _, _, _ in },
                       settingsSection: { _ in }),
            events: EventsHost(subscribe: { [unowned self] event, handler in
                handlers[event] = handler
                return Subscription(onCancel: { [unowned self] in cancelled += 1 })
            }))
    }

    func testActivateRegistersTimelinePanelAndSubscribesArchiveChanged() {
        let mock = MockHost()
        let ext = TimelineExtension()
        ext.activate(host: mock.host)
        XCTAssertEqual(mock.registeredPanels.map(\.id), ["timeline.panel"])
        XCTAssertEqual(mock.registeredPanels[0].title, "Timeline")
        XCTAssertEqual(mock.registeredPanels[0].shortcut, "cmd+shift+t")
        XCTAssertNotNil(mock.handlers[.archiveChanged],
                        "closes and Forgets must re-derive the list")
        // No panel built yet: the event handler must be a safe no-op.
        mock.handlers[.archiveChanged]?(
            HostEventPayload(event: .archiveChanged, tab: nil))
        ext.deactivate()
        XCTAssertEqual(mock.cancelled, 1, "deactivate cancels the subscription")
    }
}
