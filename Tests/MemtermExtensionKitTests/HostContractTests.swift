import AppKit
import XCTest
import MemtermExtensionKit

// Contract tests for the kit surface (kit v0): the Host struct against a
// mock implementation. These pin the API shape the future extension targets
// compile against, the archive-STUB contract (empty results until schema
// v6), the lifecycle protocol, and Subscription semantics. The kit is
// internal and free to break — but a break must be a deliberate diff here,
// never an accident.

final class HostContractTests: XCTestCase {

    /// A recording mock Host: every call lands in `calls`.
    private final class Recorder {
        var calls: [String] = []
        var subscriptions: [(event: HostEvent, handler: (HostEventPayload) -> Void)] = []
        var cancelled = 0

        lazy var host = MemtermHost(
            archive: ArchiveHost(
                query: { [unowned self] q in
                    calls.append("archive.query limit=\(q.limit)"); return []
                },
                search: { [unowned self] text in
                    calls.append("archive.search \(text)"); return []
                },
                frozenScrollback: { [unowned self] id in
                    calls.append("archive.frozenScrollback \(id.raw)"); return nil
                },
                requestForget: { [unowned self] id in
                    calls.append("archive.requestForget \(id.raw)")
                }),
            claude: ClaudeHost(
                projects: { [unowned self] in
                    calls.append("claude.projects")
                    return [ClaudeProject(slug: "s", sessionCount: 1, lastActivity: nil)]
                },
                sessions: { [unowned self] project in
                    calls.append("claude.sessions \(project.slug)")
                    return [ClaudeSessionInfo(id: ClaudeSessionID(raw: "u"),
                                              projectSlug: project.slug,
                                              lastActivity: Date(), isLive: true,
                                              needsAttention: false, lastPrompt: nil,
                                              cwd: nil, claudeVersion: nil)]
                }),
            workspace: WorkspaceHost(
                openTab: { [unowned self] cwd, ws in
                    calls.append("workspace.openTab \(cwd?.path ?? "-") \(ws?.raw ?? "-")")
                    return TabRef(tabId: "t1")
                },
                reopenGhost: { [unowned self] id, _ in
                    calls.append("workspace.reopenGhost \(id.raw)"); return nil
                },
                stageResume: { [unowned self] id, tab in
                    calls.append("workspace.stageResume \(id.raw) on=\(tab.tabId)")
                    return true
                }),
            ui: UIHost(
                registerPanel: { [unowned self] id, title, _, _ in
                    calls.append("ui.registerPanel \(id) \(title)")
                },
                setBadge: { [unowned self] tab, state in
                    calls.append("ui.setBadge \(tab.tabId) \(state)")
                },
                addTabContextMenuItem: { [unowned self] title, _, _ in
                    calls.append("ui.addTabContextMenuItem \(title)")
                },
                settingsSection: { [unowned self] section in
                    calls.append("ui.settingsSection \(section.title) rows=\(section.rows.count)")
                }),
            events: EventsHost(subscribe: { [unowned self] event, handler in
                calls.append("events.subscribe \(event)")
                subscriptions.append((event, handler))
                return Subscription(onCancel: { [unowned self] in cancelled += 1 })
            }))
    }

    /// A minimal extension exercising the whole surface on activation.
    private final class ProbeExtension: MemtermExtension {
        static let extensionId = "probe"
        var subscription: Subscription?
        var received: [HostEvent] = []
        var deactivated = false

        func activate(host: MemtermHost) {
            _ = host.archive.query(ArchiveQuery(limit: 7))
            _ = host.archive.search("needle")
            _ = host.archive.frozenScrollback(SessionID(raw: "arch1"))
            host.archive.requestForget(SessionID(raw: "arch2"))
            let projects = host.claude.projects()
            _ = host.claude.sessions(projects[0])
            let tab = host.workspace.openTab(URL(fileURLWithPath: "/tmp"),
                                             WorkspaceID(raw: "ws1"))!
            _ = host.workspace.reopenGhost(SessionID(raw: "arch3"), nil)
            _ = host.workspace.stageResume(ClaudeSessionID(raw: "uuid-1"), tab)
            host.ui.registerPanel("probe.panel", "Probe", nil) { NSViewController() }
            host.ui.setBadge(tab, .attention)
            host.ui.addTabContextMenuItem("Probe Item", { true }, {})
            host.ui.settingsSection(SettingsSection(title: "Probe", rows: [
                SettingsRow(label: "Row") { NSView() },
            ]))
            subscription = host.events.subscribe(.claudeSessionsChanged) { [weak self] payload in
                self?.received.append(payload.event)
            }
        }

        func deactivate() { deactivated = true }
    }

    func testAllFourteenCallsRouteThroughTheHost() {
        let recorder = Recorder()
        let ext = ProbeExtension()
        ext.activate(host: recorder.host)
        XCTAssertEqual(recorder.calls, [
            "archive.query limit=7",
            "archive.search needle",
            "archive.frozenScrollback arch1",
            "archive.requestForget arch2",
            "claude.projects",
            "claude.sessions s",
            "workspace.openTab /tmp ws1",
            "workspace.reopenGhost arch3",
            "workspace.stageResume uuid-1 on=t1",
            "ui.registerPanel probe.panel Probe",
            "ui.setBadge t1 attention",
            "ui.addTabContextMenuItem Probe Item",
            "ui.settingsSection Probe rows=1",
            "events.subscribe claudeSessionsChanged",
        ], "the 14-call surface, each routed exactly once")
        ext.deactivate()
        XCTAssertTrue(ext.deactivated)
    }

    func testEventsReachTheSubscriberHandler() {
        let recorder = Recorder()
        let ext = ProbeExtension()
        ext.activate(host: recorder.host)
        let (event, handler) = recorder.subscriptions[0]
        XCTAssertEqual(event, .claudeSessionsChanged)
        handler(HostEventPayload(event: .claudeSessionsChanged, tab: nil))
        XCTAssertEqual(ext.received, [.claudeSessionsChanged])
    }

    func testSubscriptionCancelIsIdempotentAndFiresOnDeinit() {
        var cancels = 0
        var subscription: Subscription? = Subscription(onCancel: { cancels += 1 })
        subscription?.cancel()
        subscription?.cancel()
        XCTAssertEqual(cancels, 1, "explicit cancel fires once")
        subscription = nil
        XCTAssertEqual(cancels, 1, "deinit after cancel does not re-fire")

        var deinitCancels = 0
        var dropped: Subscription? = Subscription(onCancel: { deinitCancels += 1 })
        _ = dropped
        dropped = nil
        XCTAssertEqual(deinitCancels, 1, "dropping the handle cancels — no leaked subscriptions")
    }

    func testArchiveStubContractIsEmptyNotCrashing() {
        // The kit's documented v0 contract for a stub Host implementation.
        let stub = ArchiveHost(query: { _ in [] }, search: { _ in [] },
                               frozenScrollback: { _ in nil }, requestForget: { _ in })
        XCTAssertEqual(stub.query(ArchiveQuery()), [])
        XCTAssertEqual(stub.search("anything"), [])
        XCTAssertNil(stub.frozenScrollback(SessionID(raw: "x")))
        stub.requestForget(SessionID(raw: "x"))  // no-op, no crash
        XCTAssertEqual(ArchiveQuery().limit, 50, "default query limit")
    }

    func testIdentityTypesAreDistinctAndHashable() {
        // ClaudeSessionID ≠ SessionID by TYPE — an archive id can never be
        // passed where a claude session UUID is expected (compile-time; here
        // we pin the value semantics).
        XCTAssertEqual(ClaudeSessionID(raw: "a"), ClaudeSessionID(raw: "a"))
        XCTAssertNotEqual(ClaudeSessionID(raw: "a"), ClaudeSessionID(raw: "b"))
        XCTAssertEqual(Set([TabRef(tabId: "t"), TabRef(tabId: "t")]).count, 1)
        XCTAssertEqual(Set([WorkspaceID(raw: "w"), WorkspaceID(raw: "x")]).count, 2)
    }
}
