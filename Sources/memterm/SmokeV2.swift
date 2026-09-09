import AppKit
import MemtermCore

// Smoke v2 (TESTING.md §2.6): the two-run capture→restore shape is kept —
// run 1 (--smoke=save) saves through the REAL capture pipeline and exits
// without teardown (deliberate crash simulation), run 2 (--smoke=verify)
// asserts through the REAL launch-restore pipeline. What changed: explicit
// run selection (no inference from restoredAnything), fresh mktemp state dirs
// (main.swift enforces the marker/empty-dir protocol), the SMOKE sentinel
// protocol under ProbeRunner, and the restored-geometry golden.
//
// Keep-list preserved verbatim: identity sets over controllers AND panes,
// kill(pid,0) on the original shell pids, byte-identical frame checks across
// FR-59 switches, FR-56 archive-on-user-close (SEMANTICS AMENDED 2026-09-02:
// the leg asserts archived-not-restored instead of gone-forever — see
// save-close-forget), parked-not-restored, the real zsh integration history
// check, restoredDividerCount, and run 1's exit()-as-crash-simulation
// (named: SMOKE-SAVE crash-sim=true).

extension MemtermAppDelegate {

    func runSmoke(run: SmokeRun, restoredAnything: Bool) {
        ProbeSupport.refuseRealStateDir(prefix: "SMOKE")
        print("SMOKE-STATE-DIR \(MemoryEngine.baseDir.path)")
        let smoke = ProbeRunner(prefix: "SMOKE", mode: run.rawValue)
        smoke.diagnostics = { [weak self] _ in
            guard let self else { return }
            for (i, controller) in self.controllers.enumerated() {
                print("SMOKE-DUMP tree[\(i)]:\n\(controller.probeTreeDump())")
            }
        }
        switch run {
        case .save: buildSaveSteps(smoke)
        case .verify:
            guard restoredAnything else {
                print("SMOKE-FAIL run=verify restored nothing from \(MemoryEngine.baseDir.path)")
                exit(1)
            }
            buildVerifySteps(smoke)
        }
        smoke.run()
    }

    // MARK: - Run 1: --smoke=save

    private func buildSaveSteps(_ smoke: ProbeRunner) {
        // FR-59 live-switch leg state: Default's identity before switching.
        var workspaceB: String?
        var defaultControllerIds = Set<ObjectIdentifier>()
        var defaultPaneIds = Set<ObjectIdentifier>()
        var defaultPids: [pid_t] = []
        var defaultFrame = NSRect.zero
        func defaultControllers() -> [TerminalWindowController] {
            controllers.filter { $0.workspaceId == StateStore.defaultWorkspaceId }
        }

        // Build 1 window / 2 tabs / 3 panes, cd one pane; the REAL capture
        // pipeline (2 s poll + zsh integration hooks) records it. The
        // condition waits on the pipeline's OUTPUT, not on a wall clock.
        smoke.add(ProbeStep(
            name: "save-build-fixtures",
            action: { [self] in
                controllers.first?.splitCurrentPane(vertical: true)
                newWindowForTab(nil)
                controllers.first?.allPanes().first?.send(txt: "cd /tmp\r")
            }))
        smoke.add(ProbeStep(
            name: "save-capture", timeout: 30,
            condition: { [self] in
                guard defaultControllers().count == 2,
                      defaultControllers().flatMap({ $0.allPanes() }).count == 3,
                      let pane = controllers.first?.allPanes().first
                else { return false }
                // The kernel-truth cwd poll (2 s cadence) must have observed
                // the cd'd pane IN /tmp — not just any cwd — before the
                // journal is worth flushing.
                guard let cwd = pane.lastKnownCwd, cwd.hasSuffix("/tmp") else {
                    return false
                }
                // And the REAL zsh integration must have written the command
                // into the per-tab history (when it applies at all).
                if config.shellIntegration,
                   ShellIntegration.isZsh(shellPath: pane.shellPath ?? ""),
                   let engine = memory, engine.shellIntegrationDir != nil {
                    let histURL = ShellIntegration.histFileURL(
                        dir: engine.historyDir, paneId: pane.paneId)
                    let hist = (try? String(contentsOf: histURL, encoding: .utf8)) ?? ""
                    return hist.contains("cd /tmp")
                }
                return true
            },
            assert: { [self] in
                memory?.flushSync()
                guard let counts = memory?.store.counts() else {
                    throw ProbeFailure("no store")
                }
                print("SMOKE-SAVED windows=\(counts.windows) tabs=\(counts.tabs) panes=\(counts.panes)")
                // Per-tab shell history: the pane that ran 'cd /tmp' runs the
                // REAL zsh integration — its .hist file must hold the command.
                if let pane = controllers.first?.allPanes().first, let engine = memory {
                    let shellPath = pane.shellPath ?? ""
                    if config.shellIntegration,
                       ShellIntegration.isZsh(shellPath: shellPath),
                       engine.shellIntegrationDir != nil {
                        let histURL = ShellIntegration.histFileURL(
                            dir: engine.historyDir, paneId: pane.paneId)
                        let hist = (try? String(contentsOf: histURL, encoding: .utf8)) ?? ""
                        guard hist.contains("cd /tmp") else {
                            throw ProbeFailure("pane history missing 'cd /tmp' at \(histURL.path) (contents: \(hist.prefix(200)))")
                        }
                        print("SMOKE-HIST captured=true entries=\(hist.split(separator: "\n").count)")
                    } else {
                        print("SMOKE-HIST skipped (shell \(shellPath) is not zsh or integration off)")
                    }
                }
            }))

        // FR-59 leg: record Default's identity, switch to fresh workspace B —
        // Default's tabs must stay LIVE (same objects, processes untouched).
        smoke.add(ProbeStep(
            name: "save-live-switch-hide", timeout: 10,
            action: { [self] in
                let defaults = defaultControllers()
                defaultControllerIds = Set(defaults.map(ObjectIdentifier.init))
                let panes = defaults.flatMap { $0.allPanes() }
                defaultPaneIds = Set(panes.map(ObjectIdentifier.init))
                defaultPids = panes.compactMap { $0.process?.shellPid }
                defaultFrame = defaults.first?.window?.frame ?? .zero
                guard defaults.count == 2, panes.count == 3, defaultPids.count == 3 else {
                    probeFail("live-switch precondition: tabs=\(defaults.count) panes=\(panes.count) pids=\(defaultPids.count)")
                }
                workspaceB = createWorkspace(named: "B")
                if let b = workspaceB { switchToWorkspace(b) }
            },
            condition: {
                // Hidden, not closed: windows off screen, shells alive,
                // controllers still registered.
                let defaults = defaultControllers()
                let hidden = !defaults.isEmpty
                    && defaults.allSatisfy { $0.window?.isVisible != true }
                let alive = defaultPids.allSatisfy { kill($0, 0) == 0 }
                let sameObjects = Set(defaults.map(ObjectIdentifier.init)) == defaultControllerIds
                return hidden && alive && sameObjects
            },
            onFailure: {
                let defaults = defaultControllers()
                print("SMOKE-DEBUG live-switch hide: hidden=\(defaults.allSatisfy { $0.window?.isVisible != true }) alive=\(defaultPids.allSatisfy { kill($0, 0) == 0 }) sameObjects=\(Set(defaults.map(ObjectIdentifier.init)) == defaultControllerIds)")
            }))
        smoke.add(ProbeStep(
            name: "save-live-switch-show", timeout: 10,
            action: { [self] in switchToWorkspace(StateStore.defaultWorkspaceId) },
            condition: {
                let defaults = defaultControllers()
                return defaults.contains { $0.window?.isVisible == true }
                    && Set(defaults.map(ObjectIdentifier.init)) == defaultControllerIds
            },
            assert: {
                let defaults = defaultControllers()
                let panes = defaults.flatMap { $0.allPanes() }
                let sameObjects = Set(defaults.map(ObjectIdentifier.init)) == defaultControllerIds
                // Identity on the PANE object graph too, not just controllers.
                let samePanes = Set(panes.map(ObjectIdentifier.init)) == defaultPaneIds
                let visible = defaults.contains { $0.window?.isVisible == true }
                // kill(pid,0) on the ORIGINAL pre-switch pids, post round-trip.
                let survivors = defaultPids.filter { kill($0, 0) == 0 }.count
                let dividers = panes.reduce(0) { $0 + $1.restoredDividerCount }
                // Byte-identical frames under the swap model.
                let framesStable = defaults.first?.window?.frame == defaultFrame
                guard sameObjects, samePanes, visible, survivors == defaultPids.count,
                      !defaultPids.isEmpty, dividers == 0, framesStable else {
                    throw ProbeFailure("live-switch show: sameObjects=\(sameObjects) samePanes=\(samePanes) visible=\(visible) pids=\(survivors)/\(defaultPids.count) dividers=\(dividers) framesStable=\(framesStable) before=\(defaultFrame) after=\(String(describing: defaults.first?.window?.frame))")
                }
                print("SMOKE-LIVE-SWITCH pids_survived=\(survivors) same_panes=\(samePanes) frames_stable=\(framesStable)")
            }))

        // Park leg (FR-51): B — hidden but live — gets parked (the explicit
        // destructive-but-remembered gesture).
        smoke.add(ProbeStep(
            name: "save-park-b",
            assert: { [self] in
                guard let engine = memory, let b = workspaceB else {
                    throw ProbeFailure("no workspace B to park")
                }
                parkWorkspace(b)
                engine.flushSync()
                let list = engine.store.listWorkspaces()
                let parked = list.filter(\.isParked).count
                let activeTabs = engine.store.loadState(workspaceId: activeWorkspaceId)
                    .reduce(0) { $0 + $1.tabs.count }
                print("SMOKE-WS workspaces=\(list.count) parked=\(parked) active_tabs=\(activeTabs)")
                guard parked == 1 else { throw ProbeFailure("B not parked") }
            }))

        // Founder bug 2026-09-09 ("the window opens 2x with the same exact
        // workspace duplicated"): a workspace left HIDDEN-but-unparked at
        // quit (FR-59 switching) must not come back on screen next to the
        // active one. Seed that world: C is created, visited, and switched
        // away from — unparked, journaled, hidden. Run 2 asserts the launch
        // shows exactly the active workspace, then that C resurrects on
        // switch-in.
        var workspaceC: String?
        smoke.add(ProbeStep(
            name: "save-hidden-c-open", timeout: 10,
            action: { [self] in
                workspaceC = createWorkspace(named: "C")
                if let c = workspaceC { switchToWorkspace(c) }
            },
            condition: { [self] in
                guard let c = workspaceC else { return false }
                return controllers.contains { $0.workspaceId == c && $0.window?.isVisible == true }
                    && defaultControllers().allSatisfy { $0.window?.isVisible != true }
            }))
        smoke.add(ProbeStep(
            name: "save-hidden-c-leave", timeout: 10,
            action: { [self] in switchToWorkspace(StateStore.defaultWorkspaceId) },
            condition: { [self] in
                guard let c = workspaceC else { return false }
                return defaultControllers().contains { $0.window?.isVisible == true }
                    && controllers.filter { $0.workspaceId == c }
                        .allSatisfy { $0.window?.isVisible != true }
            },
            assert: { [self] in
                guard let engine = memory, let c = workspaceC else {
                    throw ProbeFailure("no workspace C")
                }
                engine.flushSync()
                let row = engine.store.listWorkspaces().first { $0.id == c }
                let windows = engine.store.loadState(workspaceId: c).count
                print("SMOKE-HIDDEN-C parked=\(row?.isParked == true) journaled_windows=\(windows)")
                guard row?.isParked == false, windows >= 1 else {
                    throw ProbeFailure("hidden C must be unparked with journal rows (parked=\(String(describing: row?.isParked)) windows=\(windows))")
                }
            }))

        // Quake-style drop-down (2026-09-09): a panel with a live shell is
        // left open in the default workspace so run 2 proves it restores AS
        // a panel — role kept, hidden, its tab live — not as a plain window.
        smoke.add(ProbeStep(
            name: "save-dropdown-panel", timeout: 10,
            action: { [self] in
                var c = config
                c.dropdownEnabled = true
                c.dropdownAnimationMs = 0
                applyConfigLive(c)
                dropdown.show()
            },
            condition: { [self] in
                dropdown.panelHost?.selectedTab?.allPanes().first?.process?.running == true
            },
            assert: { [self] in
                guard let engine = memory else { throw ProbeFailure("no engine") }
                engine.flushSync()
                let rows = engine.store.loadState(workspaceId: StateStore.defaultWorkspaceId)
                let panel = rows.contains { $0.isDropdown }
                print("SMOKE-DROPDOWN journaled_role=\(panel) windows=\(rows.count)")
                guard panel else { throw ProbeFailure("drop-down panel not journaled with its role") }
            }))

        // FR-56 leg — SEMANTICS UPDATED with the founder-amended FR-56
        // (approved 2026-09-02), the ONE place the meaning legitimately
        // changes: a user close now ARCHIVES instead of deleting. This leg
        // asserts archived-not-restored — the closed tab gets a sessions row
        // with its frozen files MOVED into the archive and its live rows
        // cleaned; run 2 still asserts it is NOT restored (that half of the
        // promise is unchanged), plus that the archive row survived the
        // crash-sim relaunch.
        smoke.add(ProbeStep(
            name: "save-close-forget",
            assert: { [self] in
                guard let engine = memory, let doomed = controllers.first(where: {
                    $0.workspaceId == activeWorkspaceId && $0.allPanes().count == 1
                        && $0.host?.isDropdown != true
                }) else {
                    throw ProbeFailure("no single-pane tab to close")
                }
                let doomedTabId = doomed.tabId
                let doomedPaneIds = doomed.allPanes().map { $0.paneId }
                print("SMOKE-CLOSED tab=\(doomedTabId)")
                doomed.close()  // active-workspace user close: archives
                engine.store.barrier()
                // Archive row exists, honest reason, correct tab.
                let archived = engine.store.archivedSessions(limit: 10)
                guard let row = archived.first(where: { $0.tabId == doomedTabId }) else {
                    throw ProbeFailure("close did not archive: no sessions row for \(doomedTabId) (have \(archived.map(\.tabId)))")
                }
                guard row.closeReason == SessionCloseReason.userClose.rawValue else {
                    throw ProbeFailure("archived close_reason=\(row.closeReason), want user-close")
                }
                // Frozen files moved into <archive>/<rowid>/.
                let sessionDir = StateStore.archiveSessionDir(engine.archiveDir, id: row.id)
                guard FileManager.default.fileExists(
                    atPath: sessionDir.appendingPathComponent("scrollback.txt").path) else {
                    throw ProbeFailure("archived session \(row.id) has no frozen scrollback.txt")
                }
                // Live tables clean: the pane's row and file are gone.
                for paneId in doomedPaneIds {
                    guard !FileManager.default.fileExists(
                        atPath: engine.scrollbackURL(for: paneId).path) else {
                        throw ProbeFailure("live scrollback file survived the archive move")
                    }
                }
                print("SMOKE-ARCHIVED session=\(row.id) reason=\(row.closeReason) files=ok")
            }))
        smoke.add(ProbeStep(
            name: "save-final-flush",
            assert: { [self] in
                guard let engine = memory else { throw ProbeFailure("no engine") }
                engine.flushSync()
                let counts = engine.store.counts()
                print("SMOKE-AFTER-CLOSE windows=\(counts.windows) tabs=\(counts.tabs) panes=\(counts.panes)")
                // Protocol marker (§2.6): --smoke=verify refuses a dir
                // without it.
                let marker = MemoryEngine.baseDir
                    .appendingPathComponent(SmokeRun.markerFileName)
                try? "saved-by \(BuildStamp.describe)\n".write(to: marker, atomically: true,
                                                               encoding: .utf8)
                // Deliberate exit()-without-teardown at PASS (the runner's
                // exit(0) skips applicationShouldTerminate): the journal
                // must survive a hard kill — a feature, named in the output.
                print("SMOKE-SAVE crash-sim=true")
            }))
    }

    // MARK: - Run 2: --smoke=verify

    private func buildVerifySteps(_ smoke: ProbeRunner) {
        smoke.add(ProbeStep(
            name: "verify-restored-topology", timeout: 15,
            condition: { [self] in
                !hosts.filter { !$0.tabs.isEmpty }.isEmpty
                    && controllers.flatMap({ $0.allPanes() })
                        .allSatisfy { $0.frame.width >= 1 && $0.frame.height >= 1 }
            },
            assert: { [self] in
                // The drop-down panel restores AS a panel: hidden, role kept,
                // its tab live; it is not one of the normal windows counted
                // below.
                let panelHosts = hosts.filter { $0.isDropdown }
                let panelHidden = panelHosts.allSatisfy { $0.window?.isVisible != true }
                let panelTabs = panelHosts.flatMap(\.tabs)
                print("SMOKE-DROPDOWN restored_panels=\(panelHosts.count) hidden=\(panelHidden) panel_tabs=\(panelTabs.count) panel_ws=\(panelHosts.first?.workspaceId ?? "nil")")
                guard panelHosts.count == 1, panelHidden, panelTabs.count == 1,
                      panelHosts[0].workspaceId == StateStore.defaultWorkspaceId else {
                    throw ProbeFailure("drop-down panel did not restore as a hidden panel")
                }
                let windows = hosts.filter { !$0.tabs.isEmpty && !$0.isDropdown }.count
                let panes = controllers.filter { $0.host?.isDropdown != true }.flatMap { $0.allPanes() }
                let cwds = panes.compactMap { $0.lastKnownCwd }
                print("SMOKE-RESTORED windows=\(windows) tabs=\(controllers.count) panes=\(panes.count) cwds=\(cwds)")
                // Workspace assertions: parked B is listed but NOT restored.
                guard let store = memory?.store else { throw ProbeFailure("no store") }
                let list = store.listWorkspaces()
                guard let b = list.first(where: { $0.name == "B" }), b.isParked else {
                    throw ProbeFailure("workspace B missing or not parked")
                }
                if controllers.contains(where: { $0.workspaceId == b.id }) {
                    throw ProbeFailure("parked workspace B was restored")
                }
                // Founder bug 2026-09-09: hidden-but-unparked C has journal
                // rows, is NOT restored at launch, and exactly the active
                // workspace's windows are visible — no second window stacked
                // over the active one.
                guard let c = list.first(where: { $0.name == "C" }), !c.isParked else {
                    throw ProbeFailure("workspace C missing or parked")
                }
                guard !store.loadState(workspaceId: c.id).isEmpty else {
                    throw ProbeFailure("hidden workspace C lost its journal rows across the relaunch")
                }
                let visibleHosts = hosts.filter { $0.window?.isVisible == true }
                let strayVisible = visibleHosts.filter { $0.workspaceId != activeWorkspaceId }
                print("SMOKE-LAUNCH-VISIBLE hosts=\(hosts.count) visible=\(visibleHosts.count) stray=\(strayVisible.count) c_restored=\(controllers.contains { $0.workspaceId == c.id })")
                if controllers.contains(where: { $0.workspaceId == c.id }) {
                    throw ProbeFailure("hidden workspace C was restored at launch (the duplicate-window bug)")
                }
                guard strayVisible.isEmpty, !visibleHosts.isEmpty else {
                    throw ProbeFailure("launch visibility broke FR-59: \(visibleHosts.count) visible host(s), \(strayVisible.count) outside the active workspace")
                }
                // FR-56 (amended 2026-09-02): the deliberately-closed tab
                // from run 1 must NOT be restored (unchanged), while the
                // split tab (2 panes) is — but it is now ARCHIVED, not gone
                // forever: its sessions row and frozen files must have
                // survived the crash-sim relaunch (including the launch-time
                // orphan sweep and retention pass).
                let normalTabs = controllers.filter { $0.host?.isDropdown != true }.count
                guard normalTabs == 1, panes.count == 2 else {
                    throw ProbeFailure("close-forget: expected 1 tab / 2 panes restored, got \(normalTabs) tab(s) / \(panes.count) pane(s)")
                }
                guard let engine = memory else { throw ProbeFailure("no engine") }
                engine.store.barrier()  // launch sweep + retention have run
                let archived = engine.store.archivedSessions(limit: 10)
                guard let row = archived.first(where: {
                    $0.closeReason == SessionCloseReason.userClose.rawValue
                }) else {
                    throw ProbeFailure("archived session from run 1 did not survive the relaunch (have \(archived.count))")
                }
                let sessionDir = StateStore.archiveSessionDir(engine.archiveDir, id: row.id)
                guard FileManager.default.fileExists(
                    atPath: sessionDir.appendingPathComponent("scrollback.txt").path) else {
                    throw ProbeFailure("archived session \(row.id) lost its frozen scrollback across the relaunch")
                }
                print("SMOKE-ARCHIVE-SURVIVED session=\(row.id) closed_at=\(row.closedAt)")
                let parked = list.filter(\.isParked).count
                print("SMOKE-WS workspaces=\(list.count) parked=\(parked) active_tabs=\(controllers.count)")
            }))

        // Restored-geometry golden (§2.6): dump (pane → rect, dividerCount,
        // focusedTab, firstResponder target) at a fixed window size and diff
        // against the committed golden — the PreMigrationRestoreTests
        // byte-fixture pattern lifted one layer up. This is bug 1's cross-
        // reboot twin: a restore that presents collapsed geometry diffs loud.
        smoke.add(ProbeStep(
            name: "verify-restore-geometry-golden", timeout: 10,
            assert: { [self] in
                guard let host = hosts.first(where: { !$0.tabs.isEmpty && !$0.isDropdown }),
                      let window = host.window, let tab = host.selectedTab else {
                    throw ProbeFailure("no restored window for the geometry golden")
                }
                var frame = window.frame
                frame.size = NSSize(width: 980, height: 640)
                window.setFrame(frame, display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                let panes = tab.allPanes()
                let focusedIndex = host.tabs.firstIndex { $0 === host.selectedTab } ?? -1
                let dividers = panes.reduce(0) { $0 + $1.restoredDividerCount }
                let frTarget = window.firstResponder is PaneView ? "pane"
                    : String(describing: type(of: window.firstResponder as Any))
                var lines = ["window=980x640 tabs=\(host.tabs.count) focused=\(focusedIndex) first_responder=\(frTarget) dividers=\(dividers)"]
                for (i, pane) in panes.enumerated() {
                    let r = pane.convert(pane.bounds, to: tab.paneRoot)
                    lines.append("pane\(i)=\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))")
                }
                let dump = lines.joined(separator: "\n")
                for line in lines { print("SMOKE-GEOMETRY \(line)") }
                guard let goldenPath = ProcessInfo.processInfo
                    .environment["MEMTERM_SMOKE_GOLDEN"], !goldenPath.isEmpty else {
                    smoke.skipLine(step: "verify-restore-geometry-golden",
                                   reason: "MEMTERM_SMOKE_GOLDEN unset (dump printed above)")
                    return
                }
                guard let golden = try? String(contentsOfFile: goldenPath, encoding: .utf8)
                else {
                    throw ProbeFailure("golden file unreadable at \(goldenPath)")
                }
                let want = golden.trimmingCharacters(in: .whitespacesAndNewlines)
                guard dump == want else {
                    throw ProbeFailure("restored geometry diverged from golden \(goldenPath):\nGOT:\n\(dump)\nWANT:\n\(want)")
                }
                print("SMOKE-GEOMETRY golden=match")
            }))

        // The other half of the launch promise (founder bug 2026-09-09):
        // the hidden-at-quit workspace is one switch away — its journal
        // resurrects through the standard pipeline on first switch-in, and
        // the outgoing active workspace hides whole (FR-59).
        var pidsBefore: [pid_t] = []
        smoke.add(ProbeStep(
            name: "verify-lazy-resurrect-c", timeout: 15,
            action: { [self] in
                pidsBefore = controllers.flatMap { $0.allPanes() }.compactMap { $0.process?.shellPid }
                guard let c = memory?.store.listWorkspaces().first(where: { $0.name == "C" }) else {
                    probeFail("no workspace C to switch to")
                }
                switchToWorkspace(c.id)
            },
            condition: { [self] in
                guard let c = memory?.store.listWorkspaces().first(where: { $0.name == "C" }) else { return false }
                let cTabs = controllers.filter { $0.workspaceId == c.id }
                return activeWorkspaceId == c.id
                    && cTabs.contains { $0.window?.isVisible == true }
                    && cTabs.allSatisfy { $0.allPanes().allSatisfy { $0.frame.width >= 1 && $0.frame.height >= 1 } }
                    && controllers.filter { $0.workspaceId == StateStore.defaultWorkspaceId }
                        .allSatisfy { $0.window?.isVisible != true }
            },
            assert: { [self] in
                guard let c = memory?.store.listWorkspaces().first(where: { $0.name == "C" }) else {
                    throw ProbeFailure("no workspace C")
                }
                let cTabs = controllers.filter { $0.workspaceId == c.id }
                let survivors = pidsBefore.filter { kill($0, 0) == 0 }.count
                let visibleHosts = hosts.filter { $0.window?.isVisible == true }
                let stray = visibleHosts.filter { $0.workspaceId != c.id }.count
                print("SMOKE-LAZY-RESURRECT c_tabs=\(cTabs.count) visible=\(visibleHosts.count) stray=\(stray) default_pids_alive=\(survivors)/\(pidsBefore.count)")
                guard cTabs.count >= 1, stray == 0, survivors == pidsBefore.count else {
                    throw ProbeFailure("lazy resurrect of C: tabs=\(cTabs.count) stray_visible=\(stray) default pids alive \(survivors)/\(pidsBefore.count)")
                }
            }))
    }
}
