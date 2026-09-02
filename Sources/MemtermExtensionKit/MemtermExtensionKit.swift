import AppKit

// MemtermExtensionKit v0 — the ONLY module in-tree extensions may import
// (founder-approved "option B", decision doc 496a85fe: compiled-in SPM
// extension targets, plugin-shaped but not plugged-in).
//
// THE IMPORT FIREWALL (structural, compiler-enforced): extension targets
// (MemtermClaudeBrowser, MemtermTimeline, …) declare SPM dependencies on
// this target ONLY — they cannot import MemtermCore, StateStore, PaneView,
// MemoryEngine, or the app target, so the consent gesture (FR-29), the
// denylist (FR-30), StateStore writes, and the keystroke/pty path are
// structurally unreachable, not review-guarded. scripts/
// check-extension-firewall.sh re-asserts this in CI on every verify run.
//
// This kit is a DISCIPLINE, not a distribution surface: internal, unstable,
// free to break in any commit. It defines pure protocols and value types;
// the APP implements `Host` and hands one to each extension at activation.
//
// Deliberately absent, forever at this layer: pane byte ingest, pty/device
// writes, command execution, raw command strings toward a pty, adapter
// detect() registration, StateStore writes, raw SQLite, denylist/consent
// modification, and any networking hook. Extensions may PROPOSE; only the
// core gate + a user gesture DISPOSE.

// MARK: - Extension lifecycle

/// One in-tree extension. Instances are compiled in and activated by the app
/// at launch (behind a config flag once the first real extension lands);
/// `deactivate` releases everything the extension holds — subscriptions are
/// cancelled for it, but panels/menu items it registered stay registered for
/// the app's lifetime in v0 (registration is launch-time, not toggling).
public protocol MemtermExtension: AnyObject {
    /// Stable identifier ("claude-browser", "timeline") — used for panel ids,
    /// settings persistence, and diagnostics.
    static var extensionId: String { get }

    func activate(host: MemtermHost)
    func deactivate()
}

// MARK: - Host (the ~14 calls)

/// Everything an extension can ask the app to do. A plain struct of typed
/// call surfaces the app fills with its own implementations — there is no
/// subclassing and no way to reach past the closures into app internals.
public struct MemtermHost {
    public let archive: ArchiveHost
    public let claude: ClaudeHost
    public let workspace: WorkspaceHost
    public let ui: UIHost
    public let events: EventsHost

    public init(archive: ArchiveHost, claude: ClaudeHost, workspace: WorkspaceHost,
                ui: UIHost, events: EventsHost) {
        self.archive = archive
        self.claude = claude
        self.workspace = workspace
        self.ui = ui
        self.events = events
    }
}

// MARK: - Archive surface (STUBS until the archive train's schema v6)
//
// PROVISIONAL SHAPES. The decision doc's sequencing rule: the archive half
// of this kit is finalized in the same commits that land schema v6 /
// archive-on-close — freezing a query shape before the schema exists is the
// single biggest ossification risk. Until then the app's implementation
// returns empty results / nil / no-ops, and every type below may change
// freely. The FR-21 private-pane privacy filter is applied CORE-side before
// any result exists, always.

/// Journal/archive session identity (schema v6). Distinct from
/// `ClaudeSessionID` — an archived memterm session is not a Claude session.
public struct SessionID: Hashable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct ArchiveQuery: Equatable {
    /// Maximum cards returned, newest first.
    public var limit: Int
    public init(limit: Int = 50) { self.limit = limit }
}

/// One archived-session card (Timeline's render model).
public struct SessionCard: Equatable {
    public let id: SessionID
    public let title: String
    public let closedAt: Date?
    public let preview: String

    public init(id: SessionID, title: String, closedAt: Date?, preview: String) {
        self.id = id
        self.title = title
        self.closedAt = closedAt
        self.preview = preview
    }
}

/// Read-only frozen scrollback render model. Text to DISPLAY — never a
/// channel of control (content channels never get control; nothing arriving
/// through a session may trigger actions).
public struct GhostText: Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct ArchiveHost {
    /// STUB until schema v6: returns [].
    public let query: (ArchiveQuery) -> [SessionCard]
    /// STUB until schema v6 (journal FTS): returns [].
    public let search: (String) -> [SessionCard]
    /// STUB until schema v6: returns nil.
    public let frozenScrollback: (SessionID) -> GhostText?
    /// Hands core a session id; CORE owns the confirmation UI and the
    /// deletion (FR-56/57 — Forget is unforgeable by extension code).
    /// STUB until schema v6: no-op.
    public let requestForget: (SessionID) -> Void

    public init(query: @escaping (ArchiveQuery) -> [SessionCard],
                search: @escaping (String) -> [SessionCard],
                frozenScrollback: @escaping (SessionID) -> GhostText?,
                requestForget: @escaping (SessionID) -> Void) {
        self.query = query
        self.search = search
        self.frozenScrollback = frozenScrollback
        self.requestForget = requestForget
    }
}

// MARK: - Claude surface (typed results of core-side ~/.claude parsing)
//
// The version-fragile ~/.claude knowledge lives in ONE core site
// (REQUIREMENTS §8 / FR-35; Adapters.swift). Extensions receive these typed
// results — never raw paths, never jsonl contents — so the browser cannot
// fork version-fragile parsing.

/// A Claude Code session UUID (from a session jsonl filename / the live
/// session registry). Core re-validates before any use — holding one grants
/// no authority.
public struct ClaudeSessionID: Hashable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

/// One Claude Code project directory (a slug under ~/.claude/projects).
/// The slug encoding is lossy (every non-alphanumeric of the cwd became
/// '-'), so no path is derived from it — per-session `cwd` carries the
/// honest path when one is known.
public struct ClaudeProject: Hashable {
    public let slug: String
    public let sessionCount: Int
    public let lastActivity: Date?

    public init(slug: String, sessionCount: Int, lastActivity: Date?) {
        self.slug = slug
        self.sessionCount = sessionCount
        self.lastActivity = lastActivity
    }
}

public struct ClaudeSessionInfo: Equatable {
    public let id: ClaudeSessionID
    public let projectSlug: String
    /// Session jsonl mtime — when Claude last wrote.
    public let lastActivity: Date
    /// True when the live-session registry names this session under a
    /// process that is still running.
    public let isLive: Bool
    /// Heuristic (documented in core): live but quiet for a while — most
    /// likely waiting on the user (a prompt, a permission ask).
    public let needsAttention: Bool
    /// The user's most recent prompt, when the jsonl tail carries one.
    public let lastPrompt: String?
    /// The session's working directory, when known (registry or jsonl).
    public let cwd: String?
    /// Claude Code version that wrote the session, when known — the
    /// version-gating hook for consumers.
    public let claudeVersion: String?

    public init(id: ClaudeSessionID, projectSlug: String, lastActivity: Date,
                isLive: Bool, needsAttention: Bool, lastPrompt: String?,
                cwd: String?, claudeVersion: String?) {
        self.id = id
        self.projectSlug = projectSlug
        self.lastActivity = lastActivity
        self.isLive = isLive
        self.needsAttention = needsAttention
        self.lastPrompt = lastPrompt
        self.cwd = cwd
        self.claudeVersion = claudeVersion
    }
}

public struct ClaudeHost {
    /// All known projects, most recently active first.
    public let projects: () -> [ClaudeProject]
    /// A project's sessions, most recently active first, with liveness and
    /// needs-attention state resolved core-side.
    public let sessions: (ClaudeProject) -> [ClaudeSessionInfo]

    public init(projects: @escaping () -> [ClaudeProject],
                sessions: @escaping (ClaudeProject) -> [ClaudeSessionInfo]) {
        self.projects = projects
        self.sessions = sessions
    }
}

// MARK: - Workspace actions (safe by construction)

/// Opaque tab handle. Holding one grants no access to the tab's panes,
/// pty, or scrollback.
public struct TabRef: Hashable {
    public let tabId: String
    public init(tabId: String) { self.tabId = tabId }
}

public struct WorkspaceID: Hashable {
    public let raw: String
    public init(raw: String) { self.raw = raw }
}

public struct WorkspaceHost {
    /// Opens a NEW tab running a plain shell — never a command — in the given
    /// directory (nil = home; a vanished directory falls back like a restore
    /// would) and workspace (nil = the active one). Returns nil when the
    /// workspace does not exist.
    public let openTab: (URL?, WorkspaceID?) -> TabRef?

    /// Reopens an archived session's ghost scrollback (feed()-only by
    /// construction — core's feedRestoredPreamble path). STUB until the
    /// archive train: returns nil.
    public let reopenGhost: (SessionID, TabRef?) -> TabRef?

    /// ONE core call that stages a Claude resume offer on a tab's focused
    /// pane: core internally runs the FR-36 claims registry (a UUID already
    /// claimed by another live pane downgrades honestly to `claude
    /// --continue`), composes the offer through the adapter, gates it through
    /// the FR-30 denylist, and prints the consent-gated ⌘R offer into the
    /// pane (feed()-only). The extension never sees the command string and
    /// nothing executes without the user's ⌘R + Enter (FR-29). Returns false
    /// when nothing could be staged (bad id, no such tab, serial pane,
    /// denylisted).
    public let stageResume: (ClaudeSessionID, TabRef) -> Bool

    public init(openTab: @escaping (URL?, WorkspaceID?) -> TabRef?,
                reopenGhost: @escaping (SessionID, TabRef?) -> TabRef?,
                stageResume: @escaping (ClaudeSessionID, TabRef) -> Bool) {
        self.openTab = openTab
        self.reopenGhost = reopenGhost
        self.stageResume = stageResume
    }
}

// MARK: - UI registration

/// Extension-driven badge state for a tab, fed into the EXISTING tab
/// activity-indicator slot (spinner / unseen dot). Real pty activity always
/// outranks an extension badge, and the selected tab renders no badge (the
/// user is looking at it) — the slot's own semantics.
public enum AttentionState: Equatable {
    /// Clear this extension's badge.
    case none
    /// Something is in progress (renders as the activity spinner).
    case active
    /// Needs the user (renders as the unseen-output dot).
    case attention
}

/// One row of an extension's settings section. The row's view is the
/// extension's own (AppKit is allowed); it cannot reach memterm's config
/// file — extensions persist their own preferences.
public struct SettingsRow {
    public let label: String?
    public let makeView: () -> NSView

    public init(label: String?, makeView: @escaping () -> NSView) {
        self.label = label
        self.makeView = makeView
    }
}

public struct SettingsSection {
    public let title: String
    public let rows: [SettingsRow]

    public init(title: String, rows: [SettingsRow]) {
        self.title = title
        self.rows = rows
    }
}

public struct UIHost {
    /// Registers a managed panel window (created lazily by the app: titled,
    /// closable, frame-remembered; lifecycle, key-window, and theme duties
    /// are the APP's). `shortcut` is advisory in v0 (unwired). Register
    /// during activate() — registration is launch-time.
    public let registerPanel: (_ id: String, _ title: String, _ shortcut: String?,
                               _ make: @escaping () -> NSViewController) -> Void

    /// Feeds the existing per-tab activity-indicator slot. The extension owns
    /// clearing its badge (selecting the tab clears pty activity marks, not
    /// extension badges).
    public let setBadge: (TabRef, AttentionState) -> Void

    /// Adds an item to the tab context menu (rendered for every tab, enabled
    /// per `isEnabled`). Registered items are enumerable and typed — mild
    /// spoof risk, no authority.
    public let addTabContextMenuItem: (_ title: String, _ isEnabled: @escaping () -> Bool,
                                       _ action: @escaping () -> Void) -> Void

    /// Hangs one section off the existing Settings tabs. Register during
    /// activate() — the Settings window reads registrations when built.
    public let settingsSection: (SettingsSection) -> Void

    public init(registerPanel: @escaping (String, String, String?, @escaping () -> NSViewController) -> Void,
                setBadge: @escaping (TabRef, AttentionState) -> Void,
                addTabContextMenuItem: @escaping (String, @escaping () -> Bool, @escaping () -> Void) -> Void,
                settingsSection: @escaping (SettingsSection) -> Void) {
        self.registerPanel = registerPanel
        self.setBadge = setBadge
        self.addTabContextMenuItem = addTabContextMenuItem
        self.settingsSection = settingsSection
    }
}

// MARK: - Events

public enum HostEvent: Hashable {
    /// Something under ~/.claude changed (core wraps FSEvents; coalesced).
    /// Re-query claude.projects()/sessions(in:) — the payload carries no data.
    case claudeSessionsChanged
    /// A tab was torn down (closed by the user, quit, park, forget).
    case tabClosed
    /// STUB until the archive train: never fires.
    case archiveChanged
}

public struct HostEventPayload {
    public let event: HostEvent
    /// For .tabClosed: which tab.
    public let tab: TabRef?

    public init(event: HostEvent, tab: TabRef?) {
        self.event = event
        self.tab = tab
    }
}

/// Cancellation handle. Cancels on deinit too, so an extension dropping the
/// handle stops receiving events instead of leaking a subscription.
public final class Subscription {
    private var onCancel: (() -> Void)?

    public init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel?()
        onCancel = nil
    }

    deinit { cancel() }
}

public struct EventsHost {
    /// Handlers run on the main thread.
    public let subscribe: (HostEvent, @escaping (HostEventPayload) -> Void) -> Subscription

    public init(subscribe: @escaping (HostEvent, @escaping (HostEventPayload) -> Void) -> Subscription) {
        self.subscribe = subscribe
    }
}
