import AppKit
import MemtermCore
import UserNotifications

// FR-61 / FR-62 — always-on agent status, app side
// (spec: docs/superpowers/specs/2026-11-20-agent-status-design.md).
//
// MemoryEngine's 2 s poll sets `PaneView.agentKind`; this controller
// evaluates ONLY those panes — on pty output (coalesced to 300 ms), on a
// title change, on an OSC 7501 report, and on a 1 s tick — feeds
// MemtermCore's AgentAttentionTracker, and pushes the result to the tab
// strip, the workspace chips, the Dock badge and the alert sink. Panes
// without an agent cost nothing. Read-only: nothing here types or runs.

/// Where alerts go. The system sink posts notifications, plays the sound
/// and sets the Dock badge; probe and smoke runs record instead.
protocol AgentAlertSink: AnyObject {
    func alert(_ alert: AgentAttentionTracker.Alert, tabName: String, paneId: String,
               looking: Bool, config: Config)
    func setDockBadge(_ count: Int)
}

/// Probe/smoke sink: never touches Notification Center, NSSound or the Dock.
final class RecordingAgentAlertSink: AgentAlertSink {
    struct Entry: Equatable {
        let alert: AgentAttentionTracker.Alert
        let paneId: String
        let looking: Bool
    }
    private(set) var entries: [Entry] = []
    private(set) var dockBadge = 0

    func alert(_ alert: AgentAttentionTracker.Alert, tabName: String, paneId: String,
               looking: Bool, config: Config) {
        entries.append(Entry(alert: alert, paneId: paneId, looking: looking))
    }

    func setDockBadge(_ count: Int) { dockBadge = count }
    func reset() { entries.removeAll() }
}

final class SystemAgentAlertSink: NSObject, AgentAlertSink, UNUserNotificationCenterDelegate {
    private unowned let app: MemtermAppDelegate
    private var authorizationRequested = false
    /// UNUserNotificationCenter needs a bundle; an unbundled `swift build`
    /// binary would throw, so it simply gets no banners.
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()

    init(app: MemtermAppDelegate) {
        self.app = app
        super.init()
    }

    func alert(_ alert: AgentAttentionTracker.Alert, tabName: String, paneId: String,
               looking: Bool, config: Config) {
        let wanted = alert == .blocked ? config.agentsNotifyBlocked : config.agentsNotifyDone
        guard wanted else { return }
        if let name = config.agentsSound { NSSound(named: NSSound.Name(name))?.play() }
        // Looking at the pane already: the tab shows it, no banner needed.
        guard !looking, let center else { return }
        let post = {
            let content = UNMutableNotificationContent()
            // FR-62 privacy: the tab's name and a fixed phrase, never screen
            // content (banners can show on the lock screen).
            content.title = tabName.isEmpty ? "memterm" : tabName
            content.body = alert == .blocked ? "Needs your input" : "Finished"
            content.userInfo = ["paneId": paneId]
            // One banner per pane: a newer alert replaces the older one.
            let request = UNNotificationRequest(identifier: "agent-\(paneId)",
                                                content: content, trigger: nil)
            center.add(request)
        }
        if authorizationRequested {
            post()
        } else {
            authorizationRequested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { DispatchQueue.main.async(execute: post) }
            }
        }
    }

    func setDockBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let paneId = response.notification.request.content.userInfo["paneId"] as? String
        DispatchQueue.main.async { [weak self] in
            if let paneId { self?.app.agentStatus.reveal(paneId: paneId) }
            completionHandler()
        }
    }

    /// memterm is frontmost but the user is on another tab: still show it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

final class AgentStatusController {
    private unowned let app: MemtermAppDelegate
    let sink: AgentAlertSink
    private(set) var tracker = AgentAttentionTracker()
    /// Live OSC 7501 root reports, keyed by pane id, with the agent they
    /// were reported under (a different agent starting drops the report).
    private var reports: [String: (kind: AgentKind, status: ProgramStatus)] = [:]
    private var dirty: Set<String> = []
    private var flushWork: DispatchWorkItem?
    private var timer: Timer?
    private var shownBadges: [String: AgentBadge] = [:]
    private var shownDock = -1

    static let outputCoalesce: TimeInterval = 0.3

    init(app: MemtermAppDelegate, sink: AgentAlertSink) {
        self.app = app
        self.sink = sink
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.evaluateAll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Inputs

    func paneOutput(_ pane: PaneView) {
        guard pane.agentKind != nil, app.config.agentsStatus else { return }
        dirty.insert(pane.paneId)
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.flushWork = nil
            self?.flushDirty()
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.outputCoalesce, execute: work)
    }

    func paneTitleChanged(_ pane: PaneView) { paneOutput(pane) }

    /// OSC 7501 payload (after "7501;"). Only root reports drive a pane.
    func paneReported(_ pane: PaneView, payload: ArraySlice<UInt8>) {
        guard let text = String(bytes: payload, encoding: .utf8),
              let status = ProgramStatus.parse(text), !status.isSubRecord else { return }
        if status.isClear || status.agentState == nil {
            reports[pane.paneId] = nil
        } else if let kind = pane.agentKind {
            reports[pane.paneId] = (kind, status)
        }
        dirty.insert(pane.paneId)
        flushDirty()
    }

    /// The user looked at this tab (selected it, or its window became key):
    /// a finished agent there is seen.
    func tabLooked(_ tab: TerminalWindowController) {
        var changed = false
        for pane in tab.allPanes() where tracker.markSeen(pane: pane.paneId) { changed = true }
        if changed { publish() }
    }

    func appBecameActive() {
        if let tab = app.keyHost()?.selectedTab { tabLooked(tab) }
    }

    /// Settings flipped `[agents] status`: off clears every indicator now.
    func configChanged() { evaluateAll() }

    // MARK: Evaluation

    func evaluateAll() {
        var live: Set<String> = []
        for controller in app.controllers {
            for pane in controller.allPanes() {
                live.insert(pane.paneId)
                if pane.agentKind != nil || tracker.kind(of: pane.paneId) != nil {
                    evaluate(pane, in: controller)
                }
            }
        }
        for id in tracker.trackedPanes where !live.contains(id) {
            tracker.remove(pane: id)
            reports[id] = nil
        }
        dirty.removeAll()
        publish()
    }

    private func flushDirty() {
        guard !dirty.isEmpty else { return }
        let ids = dirty
        dirty.removeAll()
        for controller in app.controllers {
            for pane in controller.allPanes() where ids.contains(pane.paneId) {
                evaluate(pane, in: controller)
            }
        }
        publish()
    }

    private func evaluate(_ pane: PaneView, in controller: TerminalWindowController) {
        let kind = app.config.agentsStatus ? pane.agentKind : nil
        if let report = reports[pane.paneId], report.kind != kind { reports[pane.paneId] = nil }
        var detection: AgentDetection?
        if let kind {
            detection = reports[pane.paneId]?.status.detection
                ?? AgentStatusDetector.detect(kind: kind, title: pane.paneTitle,
                                              screen: pane.liveScreenText())
        }
        let looking = isLooking(controller)
        let now = ProcessInfo.processInfo.systemUptime
        if let alert = tracker.observe(pane: pane.paneId, kind: kind, detection: detection,
                                       looking: looking, now: now) {
            sink.alert(alert, tabName: controller.displayTitle, paneId: pane.paneId,
                       looking: looking, config: app.config)
        }
    }

    /// FR-62 "looking": memterm is active, the tab's window is the focused
    /// host and on screen, and the tab is selected. Probe runs are often not
    /// the active app (activation denied), so they skip the isActive term.
    func isLooking(_ tab: TerminalWindowController) -> Bool {
        guard let host = tab.host, host.selectedTab === tab,
              host === app.keyHost(), host.window?.isVisible == true else { return false }
        return NSApp.isActive || ProbeSupport.isUIProbe
    }

    // MARK: Output

    private func publish() {
        var changedTabs: [TerminalWindowController] = []
        var anyChange = false
        var seen: Set<String> = []
        for controller in app.controllers {
            var tabChanged = false
            for pane in controller.allPanes() {
                seen.insert(pane.paneId)
                let badge = tracker.badge(of: pane.paneId)
                if (shownBadges[pane.paneId] ?? .none) != badge {
                    shownBadges[pane.paneId] = badge == .none ? nil : badge
                    tabChanged = true
                }
            }
            if tabChanged { changedTabs.append(controller) }
        }
        for id in shownBadges.keys where !seen.contains(id) { shownBadges[id] = nil; anyChange = true }
        anyChange = anyChange || !changedTabs.isEmpty
        for tab in changedTabs { tab.host?.tabChanged(tab) }
        if anyChange {
            for host in app.hosts { host.refreshAgentBadges() }
        }
        let dock = app.config.agentsDockBadge ? tracker.needsYouCount : 0
        if dock != shownDock {
            shownDock = dock
            sink.setDockBadge(dock)
        }
    }

    func badge(forPane paneId: String) -> AgentBadge { tracker.badge(of: paneId) }

    func badge(forTab tab: TerminalWindowController) -> AgentBadge {
        AgentBadge.strongest(tab.allPanes().map { tracker.badge(of: $0.paneId) })
    }

    /// Workspace chip: blocked or done anywhere in the workspace. Working
    /// is left to the chip's existing output pulse.
    func badge(forWorkspace id: String) -> AgentBadge {
        let all = app.controllers.filter { $0.workspaceId == id }.map { badge(forTab: $0) }
        let strongest = AgentBadge.strongest(all)
        return strongest == .working ? .none : strongest
    }

    /// Notification click: bring the pane forward (workspace → window → tab → pane).
    func reveal(paneId: String) {
        guard let tab = app.controllers.first(where: { c in
            c.allPanes().contains { $0.paneId == paneId }
        }), let pane = tab.allPanes().first(where: { $0.paneId == paneId }) else { return }
        if tab.workspaceId != app.activeWorkspaceId { app.switchToWorkspace(tab.workspaceId) }
        guard let host = tab.host else { return }
        host.select(tab)
        host.focusWindow()
        host.window?.makeFirstResponder(pane)
        NSApp.activate(ignoringOtherApps: true)
        tabLooked(tab)
    }
}
