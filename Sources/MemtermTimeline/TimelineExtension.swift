import AppKit
import MemtermExtensionKit

// MemtermTimeline — the SECOND kit consumer (the archive train, FR-43/54):
// the session timeline. Every session the user ever closed, straight from
// host.archive.query — grouped by day with boot-UUID breaks (a reboot is a
// visible seam in the story), attributed to its workspace by color and name,
// searchable over archived command history (host.archive.search → core-side
// FTS5), with per-card actions:
//
//   "Reopen Here"  → host.workspace.openTab(cwd) + host.workspace.reopenGhost
//                    (feed()-only frozen scrollback + divider — never a pty
//                    write; this extension never sees the bytes' route).
//   "Resume"       → shown when the card carries a core-validated claude
//                    session id; the SAME consent-gated stageResume flow as
//                    everywhere else (⌘R + Enter; no command string here).
//   "Forget…"      → host.archive.requestForget — CORE owns the destructive
//                    confirmation and the TRUE deletion (FR-56/57).
//   "Reveal Files" → host.archive.revealFiles (the APP resolves the path).
//
// Parked workspaces (FR-54) appear as reopenable workspace cards from
// host.workspace.parkedWorkspaces / openWorkspace — the standard unpark
// funnel, nothing new.
//
// THE FIREWALL HOLDS HERE TOO: this target depends on MemtermExtensionKit
// alone (Package.swift; scripts/check-extension-firewall.sh). StateStore,
// the archive dir, adapter-state parsing, and the keystroke path are
// structurally out of reach.

// MARK: - Pure model (headlessly tested in MemtermTimelineTests)

public enum TimelineModel {

    /// One rendered row of the timeline list, in display order.
    public enum Row: Equatable {
        /// Day (or section) header: "Today", "Yesterday", "Tue Sep 2".
        case header(String)
        /// A boot-UUID seam inside one day: rendered "— reboot —".
        case rebootBreak
        /// A parked workspace's reopenable card (FR-54).
        case workspace(WorkspaceCard)
        case session(SessionCard)
    }

    /// "Today" / "Yesterday" / "Tue Sep 2" (adds the year once it differs:
    /// "Tue Sep 2, 2025" — an archive with a long retention must stay
    /// unambiguous).
    public static func dayLabel(for date: Date, now: Date = Date(),
                                calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = calendar.component(.year, from: date)
            == calendar.component(.year, from: now) ? "EEE MMM d" : "EEE MMM d, yyyy"
        return formatter.string(from: date)
    }

    /// Builds the render rows. `cards` must be newest-closed first (the host
    /// contract); parked workspace cards (when any) lead in their own
    /// section. Day headers appear at each day boundary; a "— reboot —"
    /// break appears between two cards of the SAME day whose boot stamps
    /// both exist and differ (a day boundary is already a visible seam).
    /// Cards with no close date land under a trailing "Earlier" section.
    public static func rows(cards: [SessionCard], parked: [WorkspaceCard],
                            now: Date = Date(),
                            calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        if !parked.isEmpty {
            rows.append(.header("Parked Workspaces"))
            rows.append(contentsOf: parked.map(Row.workspace))
        }
        var currentDayLabel: String?
        var previousCard: SessionCard?
        for card in cards {
            let label = card.closedAt.map { dayLabel(for: $0, now: now,
                                                     calendar: calendar) } ?? "Earlier"
            if label != currentDayLabel {
                rows.append(.header(label))
                currentDayLabel = label
                previousCard = nil
            } else if let prev = previousCard,
                      let a = prev.bootStamp, let b = card.bootStamp, a != b {
                rows.append(.rebootBreak)
            }
            rows.append(.session(card))
            previousCard = card
        }
        return rows
    }

    /// Compact duration: "8s", "5m", "1h 12m", "2d 3h". nil when either end
    /// is unknown or the span is not positive.
    public static func durationLabel(openedAt: Date?, closedAt: Date?) -> String? {
        guard let openedAt, let closedAt else { return nil }
        let seconds = Int(closedAt.timeIntervalSince(openedAt))
        guard seconds > 0 else { return nil }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let rest = minutes % 60
            return rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h"
        }
        let days = hours / 24
        let restHours = hours % 24
        return restHours > 0 ? "\(days)d \(restHours)h" : "\(days)d"
    }

    /// The close reason as the card whispers it (subtle, never alarming).
    public static func closeReasonLabel(_ reason: SessionCloseKind) -> String? {
        switch reason {
        case .userClose: return "closed"
        case .shellExited: return "exited"
        case .other: return nil
        }
    }
}

// MARK: - The extension

public final class TimelineExtension: MemtermExtension {
    public static let extensionId = "timeline"
    public static let panelId = "timeline.panel"

    private var host: MemtermHost?
    private var subscriptions: [Subscription] = []
    private weak var panel: TimelinePanelController?

    public init() {}

    public func activate(host: MemtermHost) {
        self.host = host
        // ⌘⇧T verified unclaimed (⌘T = Shell ▸ New Tab; nothing takes ⇧).
        host.ui.registerPanel(Self.panelId, "Timeline", "cmd+shift+t") {
            [weak self] in
            let controller = TimelinePanelController(host: host)
            self?.panel = controller
            return controller
        }
        // Closes archive, Forgets delete — either way the list re-derives.
        subscriptions.append(host.events.subscribe(.archiveChanged) {
            [weak self] _ in self?.refreshNow()
        })
    }

    public func deactivate() {
        for subscription in subscriptions { subscription.cancel() }
        subscriptions.removeAll()
        host = nil
    }

    /// Event funnel; also the probe seam (probes drive refresh synchronously
    /// instead of racing event delivery).
    public func refreshNow() {
        panel?.reload()
    }

    // MARK: Probe seams (MEMTERM_UI_PROBE legs; harmless in production)

    public var probePanel: TimelinePanelController? { panel }
}
