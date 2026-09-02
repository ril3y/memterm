import AppKit
import CoreServices
import MemtermClaudeBrowser
import MemtermCore
import MemtermExtensionKit

// The app-side implementation of MemtermExtensionKit's Host (kit v0):
// every kit call wired to the EXISTING machinery, so the kit adds surface,
// never new capability. The invariants live here, on the app side of the
// firewall:
//
//   - stageResume is ONE call into the core resume path — ClaudeSessionClaims
//     dedupe (FR-36), Adapters.resumeOffer (FR-30 denylist inside the
//     facade), and the consent-gated ⌘R offer printed via feed() only. The
//     extension never sees the command string; only the user's ⌘R types it
//     (without newline), and only Enter runs it (FR-29).
//   - openTab opens a plain shell tab, never a command.
//   - setBadge feeds the existing TabActivityIndicator slot.
//   - registerPanel creates a managed panel window (lazily, app-owned
//     lifecycle/frames).
//   - settingsSection hangs off the existing Settings tabs.
//   - archive.* are STUBS until the archive train lands schema v6 (empty
//     results, documented in the kit).
//
// NSObject: the tab-context-menu items target this object (menu validation).

final class ExtensionHostRuntime: NSObject {
    private unowned let app: MemtermAppDelegate
    private(set) var host: MemtermHost!

    /// Compiled-in extensions (decision doc: instantiated at launch). Stage
    /// 3: the Claude Sessions browser is the first real entry; MemtermTimeline
    /// follows with the archive train.
    private var activeExtensions: [any MemtermExtension] = [ClaudeBrowserExtension()]

    /// Probe seam: the compiled-in instance for an id (probes drive the
    /// browser's refresh synchronously instead of racing FSEvents).
    func compiledInExtension(id: String) -> (any MemtermExtension)? {
        activeExtensions.first { type(of: $0).extensionId == id }
    }

    // -- UI registries (launch-time; see kit docs) --
    struct PanelRegistration {
        let title: String
        let shortcut: String?
        let make: () -> NSViewController
    }
    private var panels: [String: PanelRegistration] = [:]
    private var panelWindows: [String: NSPanel] = [:]

    struct TabMenuItemRegistration {
        let title: String
        let isEnabled: () -> Bool
        let action: () -> Void
    }
    private(set) var tabMenuItems: [TabMenuItemRegistration] = []
    private(set) var settingsSections: [SettingsSection] = []

    // -- Events --
    private struct Subscriber {
        let id: UUID
        let event: HostEvent
        let handler: (HostEventPayload) -> Void
    }
    private var subscribers: [Subscriber] = []
    private var claudeWatcher: ClaudeDirWatcher?

    init(app: MemtermAppDelegate) {
        self.app = app
        super.init()
        host = MemtermHost(
            archive: ArchiveHost(
                // STUBS until the archive train (schema v6) — the kit
                // documents the contract; shapes finalize with the schema.
                query: { _ in [] },
                search: { _ in [] },
                frozenScrollback: { _ in nil },
                requestForget: { _ in }),
            claude: ClaudeHost(
                projects: { Self.mapProjects(Adapters.claudeProjectScans()) },
                sessions: { project in
                    Self.mapSessions(Adapters.claudeSessionScans(projectSlug: project.slug))
                },
                tabSessions: { [weak self] in self?.claudeTabSessions() ?? [] },
                revealSession: { [weak self] id, slug in
                    self?.revealClaudeSession(id, projectSlug: slug)
                },
                rootDisplayPath: {
                    (Adapters.defaultClaudeProjectsDir.path as NSString)
                        .abbreviatingWithTildeInPath
                }),
            workspace: WorkspaceHost(
                openTab: { [weak self] cwd, workspaceId in
                    self?.openTab(cwd: cwd, workspaceId: workspaceId)
                },
                reopenGhost: { _, _ in nil },  // STUB until the archive train
                stageResume: { [weak self] sessionId, tab in
                    self?.stageResume(sessionId, on: tab) ?? false
                }),
            ui: UIHost(
                registerPanel: { [weak self] id, title, shortcut, make in
                    self?.panels[id] = PanelRegistration(title: title,
                                                         shortcut: shortcut, make: make)
                },
                setBadge: { [weak self] tab, state in
                    self?.setBadge(tab, state)
                },
                addTabContextMenuItem: { [weak self] title, isEnabled, action in
                    self?.tabMenuItems.append(TabMenuItemRegistration(
                        title: title, isEnabled: isEnabled, action: action))
                },
                settingsSection: { [weak self] section in
                    self?.settingsSections.append(section)
                }),
            events: EventsHost(subscribe: { [weak self] event, handler in
                self?.subscribe(event, handler: handler)
                    ?? Subscription(onCancel: {})
            }))
    }

    /// Activates the compiled-in extension list. Called once at launch.
    func activateCompiledIn() {
        for ext in activeExtensions { ext.activate(host: host) }
    }

    func deactivateAll() {
        for ext in activeExtensions { ext.deactivate() }
        subscribers.removeAll()
    }

    // MARK: - Claude mapping (core scan types → kit types)

    private static func mapProjects(_ scans: [Adapters.ClaudeProjectScan]) -> [ClaudeProject] {
        scans.map {
            ClaudeProject(slug: $0.slug, sessionCount: $0.sessionCount,
                          lastActivity: $0.lastActivity)
        }
    }

    private static func mapSessions(_ scans: [Adapters.ClaudeSessionScan]) -> [ClaudeSessionInfo] {
        scans.map {
            ClaudeSessionInfo(id: ClaudeSessionID(raw: $0.id),
                              projectSlug: $0.projectSlug,
                              lastActivity: $0.lastActivity,
                              isLive: $0.isLive,
                              needsAttention: $0.needsAttention,
                              lastPrompt: $0.lastPrompt,
                              cwd: $0.cwd,
                              claudeVersion: $0.claudeVersion)
        }
    }

    // MARK: - Claude tab bindings + reveal (stage 3)

    /// Tabs whose panes' foreground process classified as claude with a
    /// resolved session id (MemoryEngine.pollPane keeps the per-pane result
    /// current). The slug comes from the pane's kernel-truth cwd via the ONE
    /// slug-encoding site — cwd → slug, never inverted.
    private func claudeTabSessions() -> [ClaudeTabSession] {
        var bindings: [ClaudeTabSession] = []
        for controller in app.controllers {
            for pane in controller.allPanes() {
                guard let sessionId = pane.lastClaudeSessionId,
                      Adapters.isValidClaudeSessionId(sessionId) else { continue }
                bindings.append(ClaudeTabSession(
                    tab: TabRef(tabId: controller.tabId),
                    id: ClaudeSessionID(raw: sessionId),
                    projectSlug: pane.lastKnownCwd.map(Adapters.claudeProjectSlug(forCwd:))))
            }
        }
        return bindings
    }

    /// Finder reveal of a session jsonl. The APP resolves the path (the
    /// extension never holds one); the id is re-validated and the slug must
    /// be a plain directory name — no traversal ever reaches the join.
    private func revealClaudeSession(_ id: ClaudeSessionID, projectSlug: String) {
        guard Adapters.isValidClaudeSessionId(id.raw),
              !projectSlug.isEmpty,
              !projectSlug.contains("/"), projectSlug != "..", projectSlug != "."
        else { return }
        let url = Adapters.defaultClaudeProjectsDir
            .appendingPathComponent(projectSlug, isDirectory: true)
            .appendingPathComponent("\(id.raw).jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Workspace actions

    /// Plain shell tab, never a command. Joins the target workspace's host
    /// (visible or hidden holder — FR-59: hidden workspaces' tabs are
    /// first-class); a hidden workspace gains a hidden host if it had none.
    /// Never yanks the user to another workspace.
    private func openTab(cwd: URL?, workspaceId: WorkspaceID?) -> TabRef? {
        let wsId = workspaceId?.raw ?? app.activeWorkspaceId
        guard app.memory?.store.listWorkspaces().contains(where: { $0.id == wsId }) == true
        else { return nil }
        let controller = TerminalWindowController(app: app, workspaceId: wsId,
                                                  initialCwd: cwd?.path)
        app.registerController(controller)
        let isActive = wsId == app.activeWorkspaceId
        if let host = app.hosts.first(where: { $0.workspaceId == wsId }) {
            host.attach(controller, select: isActive)
        } else {
            let fresh = app.makeHost(frame: nil)
            fresh.attach(controller, select: true)
            if isActive { fresh.showWindow(nil) }
            // Not active: the fresh host stays a hidden holder; the FR-59
            // switch machinery presents it when the user switches.
        }
        app.materializedWorkspaceIds.insert(wsId)
        app.memory?.scheduleTopologySave()
        app.refreshWorkspaceChips()
        return TabRef(tabId: controller.tabId)
    }

    /// The ONE core call (kit contract): claims + adapter composition +
    /// denylist + feed()-only ⌘R offer, exactly the restore path's semantics
    /// (TerminalWindowController.makeRestoredPane's claude branch).
    private func stageResume(_ sessionId: ClaudeSessionID, on tabRef: TabRef) -> Bool {
        guard Adapters.isValidClaudeSessionId(sessionId.raw),
              let controller = app.controllers.first(where: { $0.tabId == tabRef.tabId }),
              let pane = controller.currentPane(),
              !(pane is SerialPaneView)
        else { return false }
        var state = ["sessionId": sessionId.raw]
        if !app.claudeClaims.claim(sessionId: sessionId.raw, paneId: pane.paneId) {
            // FR-36/§9: the UUID is owned by another live pane — downgrade to
            // `claude --continue`, honestly labeled by the adapter.
            state["sessionId"] = nil
        }
        let snap = SnapshotRow(exe: "claude", argv: [], adapter: ClaudeAdapter.name,
                               adapterState: state)
        guard let offer = Adapters.resumeOffer(for: snap, cwdUnavailable: false)
        else { return false }
        pane.pendingResumeCommand = offer.command
        pane.feed(text: "\u{1b}[36mmemterm: resume \(offer.label) — press ⌘R to type: \(offer.command)\u{1b}[0m\r\n")
        return true
    }

    // MARK: - UI

    private func setBadge(_ tabRef: TabRef, _ state: AttentionState) {
        guard let controller = app.controllers.first(where: { $0.tabId == tabRef.tabId })
        else { return }
        switch state {
        case .none: controller.setExtensionBadge(.idle)
        case .active: controller.setExtensionBadge(.active)
        case .attention: controller.setExtensionBadge(.unseen)
        }
    }

    /// Shows (creating lazily) a registered extension panel: titled,
    /// closable, resizable, frame-remembered per panel id, never floating.
    /// Quiet automated runs (TESTING.md §2.5) position it offscreen like
    /// every other probe window instead of centering on screen.
    func showPanel(id: String) {
        if let window = panelWindows[id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let registration = panels[id] else { return }
        let rect = NSRect(x: 0, y: 0, width: 460, height: 540)
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let panel = ProbeSupport.quiet
            ? QuietExtensionPanel(contentRect: rect, styleMask: style,
                                  backing: .buffered, defer: false)
            : NSPanel(contentRect: rect, styleMask: style,
                      backing: .buffered, defer: false)
        panel.title = registration.title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.contentViewController = registration.make()
        panelWindows[id] = panel
        if ProbeSupport.quiet {
            panel.setFrameOrigin(NSPoint(x: -4000 - panel.frame.width, y: -4000))
        } else {
            // Frame memory is for real use only — automated runs (visible
            // pass included) must not write probe frames into the user's
            // defaults.
            if !ProbeSupport.isUIProbe && !ProbeSupport.isSmoke {
                panel.setFrameAutosaveName("memterm-ext-panel-\(id)")
            }
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    var registeredPanelIds: [String] { Array(panels.keys) }

    func panelWindow(id: String) -> NSPanel? { panelWindows[id] }

    // MARK: - Panel menu (registered panels join the Window menu, shortcuts
    // parsed from the kit's "cmd+shift+c" advisory form)

    /// Appends one Window-menu item per registered panel. Called once, after
    /// activateCompiledIn() — registration is launch-time (kit contract).
    func installPanelMenuItems(into menu: NSMenu) {
        guard !panels.isEmpty else { return }
        menu.addItem(.separator())
        for id in panels.keys.sorted() {
            guard let registration = panels[id] else { continue }
            let item = NSMenuItem(title: registration.title,
                                  action: #selector(showPanelMenuItem(_:)),
                                  keyEquivalent: "")
            if let (key, modifiers) = Self.parseShortcut(registration.shortcut) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = modifiers
            }
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
    }

    /// "cmd+shift+c" → ("c", [.command, .shift]). Unknown tokens void the
    /// shortcut (menu item stays, unkeyed) — advisory means never crashing.
    static func parseShortcut(_ shortcut: String?) -> (String, NSEvent.ModifierFlags)? {
        guard let shortcut, !shortcut.isEmpty else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        var key: String?
        for token in shortcut.lowercased().split(separator: "+").map(String.init) {
            switch token {
            case "cmd", "command": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "ctrl", "control": modifiers.insert(.control)
            default:
                guard token.count == 1, key == nil else { return nil }
                key = token
            }
        }
        guard let key, !modifiers.isEmpty else { return nil }
        return (key, modifiers)
    }

    @objc private func showPanelMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showPanel(id: id)
    }

    /// Appends registered extension items to a tab context menu (the strip's
    /// makeTabContextMenu calls this; empty registry appends nothing).
    func appendTabMenuItems(to menu: NSMenu) {
        guard !tabMenuItems.isEmpty else { return }
        menu.addItem(.separator())
        for (index, registration) in tabMenuItems.enumerated() {
            let item = NSMenuItem(title: registration.title,
                                  action: #selector(runTabMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
        }
    }

    @objc private func runTabMenuItem(_ sender: NSMenuItem) {
        guard tabMenuItems.indices.contains(sender.tag) else { return }
        tabMenuItems[sender.tag].action()
    }

    // MARK: - Events

    private func subscribe(_ event: HostEvent,
                           handler: @escaping (HostEventPayload) -> Void) -> Subscription {
        let id = UUID()
        subscribers.append(Subscriber(id: id, event: event, handler: handler))
        if event == .claudeSessionsChanged { ensureClaudeWatcher() }
        return Subscription(onCancel: { [weak self] in
            self?.subscribers.removeAll { $0.id == id }
        })
    }

    /// Emits on the main thread (all call sites are main-thread already).
    func emit(_ event: HostEvent, tab: TabRef? = nil) {
        let payload = HostEventPayload(event: event, tab: tab)
        for subscriber in subscribers where subscriber.event == event {
            subscriber.handler(payload)
        }
    }

    /// Lazy FSEvents watch over ~/.claude/projects + ~/.claude/sessions —
    /// started by the first .claudeSessionsChanged subscription, coalesced by
    /// FSEvents' own latency window. Watching only; nothing here reads or
    /// writes ~/.claude.
    private func ensureClaudeWatcher() {
        guard claudeWatcher == nil else { return }
        let paths = [Adapters.defaultClaudeProjectsDir.path,
                     Adapters.defaultClaudeSessionsDir.path]
            .filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return }
        claudeWatcher = ClaudeDirWatcher(paths: paths) { [weak self] in
            self?.emit(.claudeSessionsChanged)
        }
    }
}

extension ExtensionHostRuntime: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runTabMenuItem(_:)),
              tabMenuItems.indices.contains(item.tag) else { return true }
        return tabMenuItems[item.tag].isEnabled()
    }
}

/// Quiet-run twin of ProbeQuietWindow for extension panels: AppKit's frame
/// constraining would drag the offscreen panel back onto a screen.
final class QuietExtensionPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Recursive FSEvents watch (callbacks coalesced with a 0.5 s latency
/// window, delivered on the main queue).
final class ClaudeDirWatcher {
    private var stream: FSEventStreamRef?
    fileprivate let onChange: () -> Void

    init?(paths: [String], onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ClaudeDirWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
