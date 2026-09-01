import AppKit
import MemtermCore

// MEMTERM_UI_PROBE harness v2 (TESTING.md §2). Every leg from the asyncAfter
// cascade lives on as a NAMED ProbeStep — same assertions (the keep-list is
// verbatim: ObjectIdentifier identity sets, kill(pid,0), tcgetpgrp-backed
// process checks, gesture-path fidelity, journal round-trips, consent-gated
// serial restore), new scheduling and reporting. The runner owns exit: no
// leg can exit(1) silently, no partial run can read green.
//
// FOUNDER-BUG TRACEABILITY (the calibration set — which step catches which):
//   bug 1 (restored splits collapse 0x0 at launch) → "at-launch-geometry"
//     (assertPaneGeometry + assertRendered, first step of every restored/
//     observe run) + SplitLayoutTests (L2).
//   bug 2 (chips invisible at window_opacity 0.37) → "chip-contrast-rendered"
//     (+ the verify.sh config matrix incl. the founder-like config) +
//     ChromeContrastTests (L2).
//   bug 3 (close-pane blanked a restored tab) → "close-pane" run in
//     MEMTERM_PROBE_MODE=restored against the seeded restored split tab.
//   bug 4 (probe false-greens: no sentinel, fixed clocks, fresh-only
//     assumptions) → ProbeRunner's BEGIN/PASS/ABORT protocol + condition-
//     driven steps + the fresh/restored shared manifest (addStateful).
//   bug 5 (dirty/unstamped evidence) → the BEGIN line's build stamp
//     (BuildStamp) + make-app.sh dirty guard + verify.sh identity check.

extension MemtermAppDelegate {

    func runUIProbe() {
        // Belt two of two (main.swift holds the first): structurally unable
        // to touch the founder's real state (TESTING.md §2.2).
        ProbeSupport.refuseRealStateDir(prefix: "UIPROBE")
        let mode = ProbeSupport.mode
        guard ["fresh", "restored", "observe"].contains(mode) else {
            print("UIPROBE-FAIL unknown MEMTERM_PROBE_MODE=\(mode) (fresh|restored|observe)")
            exit(2)
        }
        let probe = ProbeRunner(prefix: "UIPROBE", mode: mode)
        probe.diagnostics = { [weak self] step in self?.probeFailureDump(step: step) }
        buildProbeSteps(probe, mode: mode)
        probe.run()
    }

    /// The standard failure dump (TESTING.md §2.1): tree dumps for every
    /// controller, the window list with frames, tabs debug, and a screenshot
    /// PNG under $MEMTERM_PROBE_OUT.
    private func probeFailureDump(step: String) {
        for (i, controller) in controllers.enumerated() {
            print("UIPROBE-DUMP tree[\(i)] tab=\(controller.tabId.prefix(8)) ws=\(controller.workspaceId):\n\(controller.probeTreeDump())")
        }
        for (i, window) in NSApp.windows.enumerated() {
            print("UIPROBE-DUMP window[\(i)] visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(Int(window.frame.origin.x)),\(Int(window.frame.origin.y)),\(Int(window.frame.width)),\(Int(window.frame.height)) title=\(window.title)")
        }
        if let host = keyHost() {
            print("UIPROBE-TABS-DEBUG strip_ids=\(host.tabStrip.probeTabIds()) host_tabs=\(host.tabs.map(\.tabId))")
            for (i, h) in hosts.enumerated() {
                print("UIPROBE-TABS-DEBUG host[\(i)] ws=\(h.workspaceId ?? "nil") tabs=\(h.tabs.count) visible=\(h.window?.isVisible == true)")
            }
        }
        if let path = probeScreenshot(keyHost()?.window?.contentView, name: step) {
            print("UIPROBE-DUMP screenshot=\(path)")
        }
    }

    // swiftlint:disable:next function_body_length
    private func buildProbeSteps(_ probe: ProbeRunner, mode: String) {
        let restoredWorld = mode != "fresh"

        // ---------------------------------------------------------------
        // Step: at-launch-geometry — FIRST step of every run; in restored/
        // observe runs it is the bug-1 regression gate: every restored pane
        // must PRESENT with real geometry AND rendered pixels before any
        // step creates fresh state. The old UIPROBE-TREE at_launch print is
        // an assertion now.
        // ---------------------------------------------------------------
        probe.add(ProbeStep(
            name: "at-launch-geometry", timeout: 15,
            condition: { [self] in
                guard let host = keyHost(), host.window != nil,
                      host.isTabStripVisible,
                      (host.tabStripFrameInWindow()?.height ?? 0) > 0,
                      let tab = host.selectedTab,
                      tab.paneRoot.bounds.width >= 1, tab.paneRoot.bounds.height >= 1
                else { return false }
                guard restoredWorld else { return true }
                // Restored worlds also wait for the first real paint of
                // EVERY restored pane (the shells need a beat to draw their
                // prompts) — the assert then re-checks and reports.
                guard let bmp = probeBitmap(tab.paneRoot) else { return false }
                return tab.allPanes().allSatisfy { pane in
                    let region = pane.convert(pane.bounds, to: tab.paneRoot)
                    return (try? assertRendered(bmp, region: region,
                                                what: "pane paint")) != nil
                }
            },
            assert: { [self] in
                guard let host = keyHost(), host.window != nil else {
                    throw ProbeFailure("no window at launch")
                }
                let visible = host.isTabStripVisible
                let regionHeight = host.tabStripFrameInWindow()?.height ?? 0
                print("UIPROBE-SINGLE tab_bar_visible=\(visible) strip_region_h=\(Int(regionHeight))")
                if let tab = host.selectedTab {
                    print("UIPROBE-TREE at_launch:\n\(tab.probeTreeDump())")
                }
                guard visible, regionHeight > 0 else {
                    throw ProbeFailure("single-tab tab strip not reachable")
                }
                // REGRESSION GATE (founder bug 1, restored-split collapse
                // fixed 2026-09-01 in 0225748): every multi-pane tab in every
                // host must present real pane sizes at launch — vacuous on
                // the fresh path, load-bearing in restored/observe runs.
                for h in hosts {
                    for tab in h.tabs {
                        let panes = tab.allPanes()
                        guard panes.count > 1 else { continue }
                        for pane in panes {
                            do {
                                try assertPaneGeometry(pane, paneId: pane.paneId)
                            } catch {
                                print("UIPROBE-TREE collapsed:\n\(tab.probeTreeDump())")
                                throw error
                            }
                        }
                    }
                }
                if restoredWorld {
                    // The seeded journal (a --smoke=save capture) must have
                    // restored: at least one tab, including the 2-pane split.
                    guard !controllers.isEmpty else {
                        throw ProbeFailure("restored run restored nothing")
                    }
                    guard controllers.contains(where: { $0.allPanes().count >= 2 }) else {
                        throw ProbeFailure("restored run has no multi-pane tab — seed is wrong or restore dropped the split")
                    }
                    // Rendered-pixel truth for every restored pane (bug 1's
                    // 979/0 collapse fails HERE in every restored run).
                    if let tab = host.selectedTab, let bmp = probeBitmap(tab.paneRoot) {
                        for pane in tab.allPanes() {
                            let region = pane.convert(pane.bounds, to: tab.paneRoot)
                            try assertRendered(bmp, region: region,
                                               what: "restored pane \(pane.paneId.prefix(8))")
                        }
                    }
                    print("UIPROBE-RESTORED tabs=\(controllers.count) panes=\(controllers.flatMap { $0.allPanes() }.count) geometry_ok=true rendered_ok=true")
                }
            }))

        // ---------------------------------------------------------------
        // observe mode (§2.4): the side-effect quarantine. Launch against
        // the seeded dir, create NOTHING, force NOTHING — assert the bar,
        // tabs, and restored tree exactly as a plain founder launch would
        // present them, then stop. The anti-self-masking gate.
        // ---------------------------------------------------------------
        if mode == "observe" {
            probe.add(ProbeStep(
                name: "observe-quarantine",
                assert: { [self] in
                    guard let host = keyHost(), let window = host.window else {
                        throw ProbeFailure("no window to observe")
                    }
                    if config.workspaceBar {
                        let barFrame = host.workspaceBarFrameInWindow() ?? .zero
                        guard host.workspaceBar?.window === window, barFrame.height >= 20 else {
                            throw ProbeFailure("workspace bar absent on a plain launch")
                        }
                        let chips = host.workspaceBar?.chipTitlesForProbe() ?? []
                        guard !chips.isEmpty else {
                            throw ProbeFailure("no workspace chips rendered")
                        }
                        print("UIPROBE-OBSERVE chips=\(chips)")
                    }
                    let journalTabs = memory?.store
                        .loadState(workspaceId: activeWorkspaceId)
                        .reduce(0) { $0 + $1.tabs.count } ?? -1
                    let liveTabs = controllers.filter { $0.workspaceId == activeWorkspaceId }.count
                    print("UIPROBE-OBSERVE journal_tabs=\(journalTabs) live_tabs=\(liveTabs) strip_tabs=\(host.tabStrip.probeTabIds().count)")
                    guard journalTabs == liveTabs, liveTabs == host.tabStrip.probeTabIds().count else {
                        throw ProbeFailure("presented tabs disagree with the journal on an untouched launch")
                    }
                }))
            return  // observe registers no gesture steps, by construction
        }

        // ---------------------------------------------------------------
        // Fixtures for the gesture legs. In a restored run these ADD to the
        // restored world (which step 1 already certified untouched).
        // ---------------------------------------------------------------
        var probeWorkspaceId: String?
        let tabsAtLaunch = controllers.count
        probe.addStateful(ProbeStep(
            name: "create-fixtures",
            action: { [self] in
                newWindowForTab(nil)  // second tab in the same host
                probeWorkspaceId = createWorkspace(named: "Probe")
            },
            condition: { [self] in
                guard let host = keyHost() else { return false }
                return host.tabStrip.probeTabIds().count == tabsAtLaunch + 1
                    && host.isTabStripVisible
            },
            onFailure: { [self] in
                if let host = keyHost() {
                    print("UIPROBE-TABS-DEBUG strip_ids=\(host.tabStrip.probeTabIds()) host_tabs=\(host.tabs.map(\.tabId))")
                }
            }))

        // ---------------------------------------------------------------
        // Chrome rows + strip hit-testing (founder: "workspaces on top then
        // tabs below"; gestures target tab bodies and ONLY tab bodies).
        // ---------------------------------------------------------------
        probe.add(ProbeStep(
            name: "chrome-rows-and-hit-test",
            assert: { [self] in
                guard let host = keyHost(), let window = host.window else {
                    throw ProbeFailure("no window")
                }
                let bar = host.workspaceBar
                let barFrame = host.workspaceBarFrameInWindow() ?? .zero
                let stripFrame = host.tabStripFrameInWindow() ?? .zero
                print("UIPROBE window_h=\(Int(window.frame.height)) strip_frame_minY=\(Int(stripFrame.minY))")
                print("UIPROBE bar_frame=\(Int(barFrame.minX)),\(Int(barFrame.minY)),\(Int(barFrame.width)),\(Int(barFrame.height)) in_window=\(bar?.window === window)")
                print("UIPROBE tabs_in_strip=\(host.tabStrip.probeTabIds().count) strip_visible=\(host.isTabStripVisible)")
                print("UIPROBE chips=\(bar?.chipTitlesForProbe() ?? [])")
                if config.workspaceBar {
                    print("UIPROBE bar_above_strip=\(barFrame.minY >= stripFrame.maxY - 1)")
                    guard bar?.window === window, barFrame.height >= 20 else {
                        throw ProbeFailure("workspace bar not installed in the chrome")
                    }
                    guard barFrame.minY >= stripFrame.maxY - 1 else {
                        throw ProbeFailure("workspace bar is not above the tab strip")
                    }
                }
                let strip = host.tabStrip!
                guard let firstId = strip.probeTabIds().first,
                      let firstFrame = strip.probeItemFrame(of: firstId) else {
                    throw ProbeFailure("no strip items to hit-test")
                }
                let tabHit = strip.probeTabId(atContentX: firstFrame.midX) == firstId
                let backgroundHit = strip.probeTabId(atContentX: 10_000) != nil
                let rowsDisjoint = !config.workspaceBar || !barFrame.intersects(stripFrame)
                print("UIPROBE-STRIP tab_hit=\(tabHit) background_hit=\(backgroundHit) rows_disjoint=\(rowsDisjoint)")
                guard tabHit, !backgroundHit, rowsDisjoint else {
                    throw ProbeFailure("strip hit-testing targets the wrong regions")
                }
            }))

        // ---------------------------------------------------------------
        // Step: chip-contrast-rendered — BUG 2 REGRESSION GATE. The chips'
        // visibility is asserted on the RENDERED chrome bitmap, not on model
        // colors: an invisible chip samples near-uniform and fails. verify.sh
        // runs this across the config matrix — including the founder-like
        // window_opacity=0.37 + blur config that shipped the escape.
        // ---------------------------------------------------------------
        probe.add(ProbeStep(
            name: "chip-contrast-rendered",
            assert: { [self] in
                guard config.workspaceBar else {
                    probe.skipLine(step: "chip-contrast-rendered",
                                   reason: "workspace_bar=false")
                    return
                }
                guard let host = keyHost(), let bar = host.workspaceBar else {
                    throw ProbeFailure("no workspace bar")
                }
                bar.layoutSubtreeIfNeeded()
                guard let bmp = probeBitmap(bar) else {
                    throw ProbeFailure("workspace bar produced no bitmap")
                }
                let chips = bar.probeChipFrames()
                guard !chips.isEmpty else { throw ProbeFailure("no chips rendered") }
                for (id, frame) in chips {
                    try assertChipVisible(chipFrame: frame, in: bmp,
                                          what: "chip \(id.prefix(8))")
                }
                // Text half (meta-gate hardening): the whole-chip sample can
                // be carried by the color dot / active background while the
                // NAME is invisible — sample each label's own region so
                // washed-out text fails on its own.
                let labels = bar.probeChipLabelFrames()
                guard labels.count == chips.count else {
                    throw ProbeFailure("chip labels missing: \(labels.count) labels for \(chips.count) chips")
                }
                for (id, frame) in labels {
                    try assertChipVisible(chipFrame: frame, in: bmp,
                                          what: "chip \(id.prefix(8)) label text")
                }
                // Success-path evidence for the verify report (§3.4 item 5):
                // what the gate SAW, per config, human-eyeballable.
                if let shot = probeScreenshot(bar, name: "chip-bar-opacity-\(config.windowOpacity)") {
                    print("UIPROBE-CHIPS screenshot=\(shot)")
                }
                print("UIPROBE-CHIPS rendered=\(chips.count) contrast_ok=true opacity=\(config.windowOpacity)")
            }))

        // ---------------------------------------------------------------
        // Full-tab tint (founder's ask, twice): body layer color + label
        // contrast flip — kept verbatim.
        // ---------------------------------------------------------------
        probe.add(ProbeStep(
            name: "tab-tint-contrast",
            assert: { [self] in
                guard let host = keyHost(), let selected = host.selectedTab else {
                    throw ProbeFailure("no selected tab (tint leg)")
                }
                let strip = host.tabStrip!
                selected.tabColor = "#febc2e"
                let yellowDark = strip.probeLabelColor(of: selected.tabId) == NSColor.black
                let yellowBody = strip.probeBodyColor(of: selected.tabId)
                let yellowBodyOK = yellowBody == Self.nsColor(hex: "#febc2e").cgColor
                selected.tabColor = "#0a84ff"
                let blueLight = strip.probeLabelColor(of: selected.tabId) == NSColor.white
                let blueBodyOK = strip.probeBodyColor(of: selected.tabId)
                    == Self.nsColor(hex: "#0a84ff").cgColor
                selected.tabColor = nil
                print("UIPROBE-TINT yellow_dark_text=\(yellowDark) blue_light_text=\(blueLight) yellow_body=\(yellowBodyOK) blue_body=\(blueBodyOK)")
                guard yellowDark, blueLight, yellowBodyOK, blueBodyOK else {
                    throw ProbeFailure("full-tab tint (body layer color / contrast flip)")
                }
            }))

        // ---------------------------------------------------------------
        // In-strip reorder: model order, strip mirror, journal persistence —
        // kept verbatim (journal round-trip on the keep-list).
        // ---------------------------------------------------------------
        probe.addStateful(ProbeStep(
            name: "reorder-persists",
            assert: { [self] in
                guard let host = keyHost(), host.tabs.count >= 2 else {
                    throw ProbeFailure("need 2 tabs to reorder")
                }
                let strip = host.tabStrip!
                host.tabs[0].customTitle = "R-A"
                host.tabs[1].customTitle = "R-B"
                let before = strip.probeTabIds()
                host.reorderTab(from: 0, to: 1)
                host.reorderCommitted()
                let after = strip.probeTabIds()
                let reordered = after == [before[1], before[0]]
                    && host.tabs.map(\.tabId) == after
                memory?.flushSync()
                let journalTitles = memory?.store
                    .loadState(workspaceId: activeWorkspaceId)
                    .first { $0.tabs.count == host.tabs.count }?.tabs.map(\.title) ?? []
                let journaled = journalTitles.first == "R-B"
                    && journalTitles.dropFirst().first == "R-A"
                host.reorderTab(from: 1, to: 0)  // put it back
                host.reorderCommitted()
                host.tabs[0].customTitle = nil
                host.tabs[1].customTitle = nil
                print("UIPROBE-REORDER swapped=\(reordered) journal_order=\(journaled) journal_titles=\(journalTitles)")
                guard reordered, journaled else {
                    throw ProbeFailure("strip reorder did not mirror the model / persist to the journal")
                }
            }))

        // ---------------------------------------------------------------
        // Per-tab activity: output on an unselected tab → active → decays to
        // unseen → clears on select. Condition-driven now (the old fixed
        // 0.6 s / 1.8 s gaps raced the decay clock under load).
        // ---------------------------------------------------------------
        probe.addStateful(ProbeStep(
            name: "tab-activity-marks", timeout: 10,
            action: { [self] in
                controllers.first?.allPanes().first?.send(txt: "echo probe-activity\r")
            },
            condition: { [self] in
                controllers.first?.activityStateForProbe() == .active
            },
            assert: { [self] in
                print("UIPROBE-ACT after_output=\(controllers.first.map { $0.activityStateForProbe() } ?? .idle)")
            }))
        probe.addStateful(ProbeStep(
            name: "tab-activity-decays", timeout: 10,
            condition: { [self] in
                controllers.first?.activityStateForProbe() == .unseen
            },
            assert: { [self] in
                print("UIPROBE-ACT after_decay=\(controllers.first.map { $0.activityStateForProbe() } ?? .idle)")
            }))

        // Keyboard contract: after host.select (the strip click path) the
        // first responder is a pane OF THE SELECTED TAB.
        probe.addStateful(ProbeStep(
            name: "focus-after-tab-select", timeout: 5,
            action: { [self] in
                if let first = controllers.first { first.host?.select(first) }
            },
            condition: { [self] in
                guard let host = keyHost(), let tab = host.selectedTab else { return false }
                let fr = host.window?.firstResponder as? PaneView
                return fr != nil && tab.allPanes().contains { $0 === fr }
            },
            assert: { [self] in
                let state = controllers.first.map { $0.activityStateForProbe() } ?? .idle
                print("UIPROBE-ACT after_select=\(state)")
                print("UIPROBE-FOCUS after_tab_select=true")
                guard state == .idle else {
                    throw ProbeFailure("selecting the tab must clear its activity mark")
                }
            },
            onFailure: {
                print("UIPROBE-FOCUS after_tab_select=false")
            }))

        // ---------------------------------------------------------------
        // Workspace activity + the FR-59 swap invariants (identity sets over
        // hosts, same visible window object, focus contract) — verbatim.
        // This leg also exercises the switch-fade path (fades are ON in
        // probe runs, unlike smoke — TESTING.md §2.6).
        // ---------------------------------------------------------------
        let defaultId = StateStore.defaultWorkspaceId
        var preSwitchHostIds = Set<ObjectIdentifier>()
        var preSwitchVisibleWindow: NSWindow?
        probe.addStateful(ProbeStep(
            name: "workspace-switch-hidden-output", timeout: 8,
            action: { [self] in
                guard let probeWs = probeWorkspaceId else {
                    probeFail("no Probe workspace")
                }
                print("UIPROBE-FADE enabled=\(switchFadeEnabled)")
                switchToWorkspace(probeWs)
            },
            condition: { [self] in
                activeWorkspaceId != defaultId
                    && controllers.contains {
                        $0.workspaceId == defaultId && $0.window?.isVisible != true
                    }
            },
            assert: { [self] in
                guard let hidden = controllers.first(where: { $0.workspaceId == defaultId })
                else { throw ProbeFailure("default workspace not hidden") }
                hidden.allPanes().first?.send(txt: "echo ws-activity\r")
            }))
        probe.addStateful(ProbeStep(
            name: "workspace-activity-marks", timeout: 10,
            condition: { [self] in workspaceActivityState(of: defaultId) != .idle },
            assert: { [self] in
                print("UIPROBE-WSACT after_output=\(workspaceActivityState(of: defaultId))")
            },
            onFailure: { [self] in
                print("UIPROBE-WSACT after_output=\(workspaceActivityState(of: defaultId))")
            }))
        probe.addStateful(ProbeStep(
            name: "workspace-activity-decays", timeout: 10,
            condition: { [self] in
                let chip = hosts
                    .first { $0.workspaceId == activeWorkspaceId }?
                    .workspaceBar?.chipActivityForProbe(workspaceId: defaultId)
                return workspaceActivityState(of: defaultId) == .unseen && chip == .unseen
            },
            assert: { [self] in
                print("UIPROBE-WSACT after_decay=unseen chip_state=unseen")
                // FR-59 swap invariants: record host + visible-window identity
                // so the switch-back can prove no window was created or
                // destroyed and the user keeps looking at the SAME window.
                preSwitchHostIds = Set(hosts.map(ObjectIdentifier.init))
                preSwitchVisibleWindow = hosts
                    .first { $0.window?.isVisible == true }?.window
            },
            onFailure: { [self] in
                let chip = hosts
                    .first { $0.workspaceId == activeWorkspaceId }?
                    .workspaceBar?.chipActivityForProbe(workspaceId: defaultId)
                print("UIPROBE-WSACT after_decay=\(workspaceActivityState(of: defaultId)) chip_state=\(chip.map(String.init(describing:)) ?? "nil")")
            }))
        probe.addStateful(ProbeStep(
            name: "workspace-swap-identity", timeout: 8,
            action: { [self] in switchToWorkspace(defaultId) },
            condition: { [self] in
                guard activeWorkspaceId == defaultId,
                      hosts.contains(where: { $0.window?.isVisible == true }),
                      let host = keyHost(),
                      let fr = host.window?.firstResponder as? PaneView,
                      host.selectedTab?.allPanes().contains(where: { $0 === fr }) == true
                else { return false }
                return true
            },
            assert: { [self] in
                let state = workspaceActivityState(of: defaultId)
                print("UIPROBE-WSACT after_switch=\(state)")
                guard state == .idle else {
                    throw ProbeFailure("switching back must clear the mark")
                }
                // Swap-in-place: the same host set, and the same window
                // object is the visible one.
                let sameHosts = Set(hosts.map(ObjectIdentifier.init)) == preSwitchHostIds
                let visibleNow = hosts.first { $0.window?.isVisible == true }?.window
                let sameWindow = visibleNow != nil && visibleNow === preSwitchVisibleWindow
                print("UIPROBE-SWAP same_hosts=\(sameHosts) same_visible_window=\(sameWindow) focus_in_pane=true")
                guard sameHosts, sameWindow else {
                    throw ProbeFailure("FR-59 swap must reuse the same hosts/window")
                }
            }))

        // Settings 2.0: the sectioned window must construct and load.
        probe.add(ProbeStep(
            name: "settings-window-builds",
            assert: { [self] in
                let settings = SettingsWindowController(app: self)
                print("UIPROBE-SETTINGS built=\(settings.window != nil)")
                guard settings.window != nil else {
                    throw ProbeFailure("settings window did not build")
                }
            }))

        // ---------------------------------------------------------------
        // Inline workspace rename: editor takes focus INSIDE the strip;
        // commit hands the keyboard back to the pane (FocusIntent's
        // contract; the old fixed 0.4 s deadline raced the async handoff).
        // ---------------------------------------------------------------
        var renameHost: WindowHostController?
        probe.add(ProbeStep(
            name: "rename-commit-focus", timeout: 8,
            action: { [self] in
                guard config.workspaceBar else { return }
                guard let host = keyHost() else { probeFail("no host (rename leg)") }
                renameHost = host
                host.beginWorkspaceRename(activeWorkspaceId)
                let editorFocused = host.window?.firstResponder is NSTextView
                print("UIPROBE-RENAME editor_focused=\(editorFocused)")
                if !editorFocused { probeFail("rename editor did not take focus") }
                host.window?.makeFirstResponder(nil)  // commit via end-editing
            },
            condition: { [self] in
                !config.workspaceBar || (renameHost?.window?.firstResponder is PaneView)
            },
            assert: { [self] in
                guard config.workspaceBar else {
                    probe.skipLine(step: "rename-commit-focus", reason: "workspace_bar=false")
                    return
                }
                print("UIPROBE-RENAME focus_back_to_pane=true")
            },
            onFailure: {
                print("UIPROBE-RENAME focus_back_to_pane=false")
                print("UIPROBE-RENAME-DEBUG fr=\(String(describing: renameHost?.window?.firstResponder)) isWindow=\(renameHost?.window?.firstResponder === renameHost?.window) selected=\(String(describing: renameHost?.selectedTab?.displayTitle))")
            }))

        // Esc-cancel: the rename contract's other half — store keeps the old
        // name, keyboard returns to the pane, via the REAL field-editor
        // doCommand(cancelOperation:) path (keep-list: gesture fidelity).
        probe.add(ProbeStep(
            name: "rename-esc-cancel", timeout: 8,
            action: { [self] in
                guard config.workspaceBar else { return }
                guard let host = keyHost(), let window = host.window else {
                    probeFail("no host (esc leg)")
                }
                renameHost = host
                host.beginWorkspaceRename(activeWorkspaceId)
                guard let editor = window.firstResponder as? NSTextView else {
                    probeFail("esc leg: editor did not take focus")
                }
                editor.insertText("Garbage-Name",
                                  replacementRange: NSRange(location: 0,
                                                            length: (editor.string as NSString).length))
                editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            },
            condition: { [self] in
                !config.workspaceBar || (renameHost?.window?.firstResponder is PaneView)
            },
            assert: { [self] in
                guard config.workspaceBar else {
                    probe.skipLine(step: "rename-esc-cancel", reason: "workspace_bar=false")
                    return
                }
                let names = memory?.store.listWorkspaces().map { $0.name } ?? []
                let cancelled = !names.contains("Garbage-Name")
                print("UIPROBE-ESC cancelled=\(cancelled) focus_back_to_pane=true names=\(names)")
                guard cancelled else { throw ProbeFailure("Esc did not cancel the rename cleanly") }
            },
            onFailure: {
                print("UIPROBE-ESC focus_back_to_pane=false fr=\(String(describing: renameHost?.window?.firstResponder))")
            }))

        // ---------------------------------------------------------------
        // Fullscreen. Quiet mode asserts the chrome across a frame
        // transition instead of driving a real Spaces animation (§2.5);
        // MEMTERM_PROBE_VISIBLE=1 keeps the real round-trip.
        // ---------------------------------------------------------------
        if ProbeSupport.visible {
            probe.add(ProbeStep(
                name: "fullscreen-enter", timeout: 10,
                action: { [self] in keyHost()?.window?.toggleFullScreen(nil) },
                condition: { [self] in
                    keyHost()?.window?.styleMask.contains(.fullScreen) == true
                },
                assert: { [self] in
                    let height = keyHost()?.window?.frame.height ?? 0
                    print("UIPROBE-FS entered=true frame_h=\(Int(height))")
                },
                onFailure: { print("UIPROBE-FS entered=false") }))
            probe.add(ProbeStep(
                name: "fullscreen-exit", timeout: 10,
                action: { [self] in
                    // Give the enter animation a beat, then leave.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        self.keyHost()?.window?.toggleFullScreen(nil)
                    }
                },
                condition: { [self] in
                    keyHost()?.window?.styleMask.contains(.fullScreen) == false
                },
                assert: { [self] in
                    guard let host = keyHost(), let window = host.window else {
                        throw ProbeFailure("no window (fullscreen exit)")
                    }
                    window.contentView?.layoutSubtreeIfNeeded()
                    let barFrame = host.workspaceBarFrameInWindow() ?? .zero
                    let stripFrame = host.tabStripFrameInWindow() ?? .zero
                    let barOK = !config.workspaceBar
                        || (host.workspaceBar?.window === window
                            && barFrame.minY >= stripFrame.maxY - 1)
                    print("UIPROBE-FS exited=true bar_restored=\(barOK)")
                    guard barOK else {
                        throw ProbeFailure("fullscreen round-trip wedged the chrome")
                    }
                },
                onFailure: { print("UIPROBE-FS exited=false bar_restored=false") }))
        } else {
            probe.add(ProbeStep(
                name: "fullscreen-frame-transition-quiet",
                assert: { [self] in
                    guard let host = keyHost(), let window = host.window else {
                        throw ProbeFailure("no window (fullscreen leg)")
                    }
                    let saved = window.frame
                    let big = NSRect(x: saved.origin.x, y: saved.origin.y - 300,
                                     width: 1680, height: 1000)
                    window.setFrame(big, display: true)
                    window.contentView?.layoutSubtreeIfNeeded()
                    func chromeIntact() -> Bool {
                        let barFrame = host.workspaceBarFrameInWindow() ?? .zero
                        let stripFrame = host.tabStripFrameInWindow() ?? .zero
                        guard stripFrame.width >= window.frame.width - 1 else { return false }
                        return !config.workspaceBar
                            || (barFrame.minY >= stripFrame.maxY - 1 && barFrame.height >= 20)
                    }
                    let bigOK = chromeIntact()
                    window.setFrame(saved, display: true)
                    window.contentView?.layoutSubtreeIfNeeded()
                    let restoredOK = chromeIntact() && window.frame == saved
                    print("UIPROBE-FS quiet_transition big_ok=\(bigOK) restored_ok=\(restoredOK)")
                    guard bigOK, restoredOK else {
                        throw ProbeFailure("frame transition wedged the chrome (quiet fullscreen stand-in)")
                    }
                }))
        }

        addClosePaneSteps(probe, mode: mode)
        addSerialSteps(probe)
        addWorkspaceCloseSteps(probe, probeWorkspaceId: { probeWorkspaceId })
        addTabGestureSteps(probe)

        // Composited pixel pass (visible runs only): the window-server truth
        // cacheDisplay cannot see (§2.3's documented caveat).
        if ProbeSupport.visible {
            probe.add(ProbeStep(
                name: "composited-pixel-pass",
                assert: { [self] in
                    guard let window = keyHost()?.window else {
                        throw ProbeFailure("no window for composited pass")
                    }
                    guard let cg = probeWindowImage(window) else {
                        probe.skipLine(step: "composited-pixel-pass",
                                       reason: "no screen-capture permission for CGWindowListCreateImage")
                        return
                    }
                    let bmp = NSBitmapImageRep(cgImage: cg)
                    try assertRendered(bmp, region: CGRect(origin: .zero, size: bmp.size),
                                       what: "composited window")
                    if config.workspaceBar {
                        // The chrome band (top of the window) must contain
                        // visibly contrasting pixels ON SCREEN — chips over
                        // translucency included (bug 2's composited half).
                        let band = CGRect(x: 8, y: bmp.size.height - 30,
                                          width: bmp.size.width - 16, height: 28)
                        try assertChipVisible(chipFrame: band, in: bmp,
                                              what: "composited chrome band")
                    }
                    print("UIPROBE-COMPOSITED rendered_ok=true")
                }))
        }
    }

    // MARK: - Close-pane (BUG 3 regression when mode == restored)

    private func addClosePaneSteps(_ probe: ProbeRunner, mode: String) {
        var closeProbePane: PaneView?
        var closeProbeController: TerminalWindowController?
        var closeProbePaneCountBefore = 0
        probe.addStateful(ProbeStep(
            name: "close-pane-split",
            assert: { [self] in
                // In a restored run, target the RESTORED multi-pane tab —
                // the exact world the founder's close-pane blanking hit.
                let target: TerminalWindowController?
                if mode == "restored" {
                    target = controllers.first { $0.allPanes().count > 1 }
                        ?? keyController()
                    if let target, let host = target.host {
                        host.focusWindow()
                        host.select(target)
                    }
                } else {
                    target = keyController()
                }
                guard let controller = target else {
                    throw ProbeFailure("no controller (close-pane leg)")
                }
                closeProbeController = controller
                let before = controller.allPanes()
                closeProbePaneCountBefore = before.count
                print("UIPROBE-CLOSEPANE-TREE before-split:\n\(controller.probeTreeDump())")
                controller.splitCurrentPane(vertical: false)
                let after = controller.allPanes()
                closeProbePane = after.first { pane in !before.contains { $0 === pane } }
                guard after.count == before.count + 1, closeProbePane != nil else {
                    throw ProbeFailure("split for close-pane leg (before=\(before.count) after=\(after.count))")
                }
            }))
        probe.addStateful(ProbeStep(
            name: "close-pane", timeout: 8,
            // The new pane's shell needs a beat to spawn; the condition (not
            // a clock) waits for it so close() tears down a REAL process.
            condition: { closeProbePane?.process?.running == true },
            assert: { [self] in
                guard let controller = closeProbeController, let pane = closeProbePane else {
                    throw ProbeFailure("close-pane setup lost")
                }
                let windowBefore = controller.window
                controller.close(pane: pane)
                let panes = controller.allPanes()
                let minDim = panes.map { min($0.frame.width, $0.frame.height) }.min() ?? 0
                let windowAlive = controller.window != nil && controller.window === windowBefore
                    && controllers.contains { $0 === controller }
                let shellAlive = panes.first?.process.running ?? false
                print("UIPROBE-CLOSEPANE window_alive=\(windowAlive) panes=\(panes.count) expected_panes=\(closeProbePaneCountBefore) min_pane_dim=\(Int(minDim)) shell_alive=\(shellAlive)")
                print("UIPROBE-CLOSEPANE-TREE after-close:\n\(controller.probeTreeDump())")
                guard windowAlive, panes.count == closeProbePaneCountBefore,
                      minDim >= 50, shellAlive else {
                    throw ProbeFailure("close-pane blanked the tab")
                }
            }))
    }

    // MARK: - Serial legs (pty pair — real /dev/cu.* NEVER touched; keep-list)

    private func addSerialSteps(_ probe: ProbeRunner) {
        var serialMasterFD: Int32 = -1
        var serialPane: SerialPaneView?
        probe.add(ProbeStep(
            name: "serial-open-rx", timeout: 10,
            action: { [self] in
                let master = posix_openpt(O_RDWR | O_NOCTTY)
                guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
                      let slaveC = ptsname(master),
                      case let slavePath = String(cString: slaveC), !slavePath.isEmpty else {
                    probeFail("serial leg: pty pair")
                }
                serialMasterFD = master
                // Raw master: no kernel echo/translation between the ends.
                var t = termios()
                tcgetattr(master, &t)
                cfmakeraw(&t)
                tcsetattr(master, TCSANOW, &t)
                _ = fcntl(master, F_SETFL, O_NONBLOCK)
                let setup = SerialPaneView.Setup(
                    path: slavePath, identity: "path:\(slavePath)", label: "probe-pty",
                    settings: SerialSettings(), txLineEnding: .crlf, localEcho: false)
                let controller = openSerialTab(setup: setup)
                guard let pane = controller.allPanes().first as? SerialPaneView else {
                    probeFail("serial leg: no serial pane")
                }
                serialPane = pane
                print("UIPROBE-SERIAL connected=\(pane.isConnected) title=\(pane.paneTitle)")
                if !pane.isConnected || !pane.paneTitle.contains("@ 115200") {
                    probeFail("serial pane did not connect (title=\(pane.paneTitle))")
                }
                let rx = Array("hello-serial\r\n".utf8)
                _ = rx.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            },
            condition: {
                serialPane?.scrollbackText(maxLines: 200).contains("hello-serial") == true
            },
            assert: {
                print("UIPROBE-SERIAL rx_rendered=true")
                serialPane?.send(txt: "ping\r")  // keystroke path → send override → fd
            },
            onFailure: {
                let text = serialPane?.scrollbackText(maxLines: 200) ?? ""
                print("UIPROBE-SERIAL rx_rendered=false tail=\(text.suffix(300))")
            }))
        // CRLF TX transform: the pane's Enter (CR) must arrive as CRLF; the
        // nonblocking master read accumulates across condition polls.
        var serialTxReceived = ""
        probe.add(ProbeStep(
            name: "serial-tx-crlf", timeout: 10,
            condition: {
                var buf = [UInt8](repeating: 0, count: 512)
                let n = read(serialMasterFD, &buf, buf.count)
                if n > 0 { serialTxReceived += String(decoding: buf[0..<n], as: UTF8.self) }
                return serialTxReceived.contains("ping\r\n")
            },
            assert: {
                guard let pane = serialPane else { throw ProbeFailure("serial pane lost") }
                print("UIPROBE-SERIAL tx_bytes=\(serialTxReceived.utf8.count) crlf_transform=true")
                // Local echo honored, both ways.
                let echoOffOK = !pane.scrollbackText(maxLines: 200).contains("ping")
                print("UIPROBE-SERIAL echo_off_honored=\(echoOffOK)")
                guard echoOffOK else { throw ProbeFailure("local-echo-off keystrokes rendered") }
                pane.updateLocalEcho(true)
                pane.send(txt: "echo-on-test")
                pane.setHexMode(true)
                let bytes: [UInt8] = [0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef,
                                      0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef]
                _ = bytes.withUnsafeBytes { write(serialMasterFD, $0.baseAddress, $0.count) }
            },
            onFailure: {
                print("UIPROBE-SERIAL tx_bytes=\(serialTxReceived.utf8.count) crlf_transform=false got=\(serialTxReceived.debugDescription)")
            }))
        probe.add(ProbeStep(
            name: "serial-hex-echo", timeout: 10,
            condition: {
                guard let text = serialPane?.scrollbackText(maxLines: 200) else { return false }
                return text.contains("de ad be ef") && text.contains("hex view on")
                    && text.contains("echo-on-test")
            },
            assert: { [self] in
                print("UIPROBE-SERIAL hex_lens=true echo_on_rendered=true")
                // Journal the pane (2 s poll may not have ticked): poll+flush.
                memory?.pollNow()
                memory?.flushSync()
                var journaled = false
                for window in memory?.store.loadState() ?? [] {
                    for tab in window.tabs {
                        for (_, paneRestore) in tab.panes {
                            if let snap = paneRestore.snapshot, snap.adapter == SerialAdapter.name,
                               snap.adapterState[SerialAdapter.settingsKey] == "115200-8N1",
                               snap.adapterState[SerialAdapter.pathKey]?.isEmpty == false {
                                journaled = true
                            }
                        }
                    }
                }
                print("UIPROBE-SERIAL adapter_journaled=\(journaled)")
                guard journaled else { throw ProbeFailure("serial adapter_state not journaled") }
                // "Unplug": closing the pty master REVOKES the slave; the
                // banner arrives via the 0.5 s liveness probe.
                _ = Darwin.close(serialMasterFD)
            },
            onFailure: {
                let text = serialPane?.scrollbackText(maxLines: 200) ?? ""
                print("UIPROBE-SERIAL hex/echo tail=\(text.suffix(300))")
            }))
        probe.add(ProbeStep(
            name: "serial-unplug-banner", timeout: 8,
            condition: {
                guard let pane = serialPane else { return false }
                return pane.scrollbackText(maxLines: 200)
                    .contains("device disconnected — will reconnect when it returns")
                    && !pane.isConnected
            },
            assert: {
                print("UIPROBE-SERIAL disconnect_banner=true still_connected=false")
            },
            onFailure: {
                let text = serialPane?.scrollbackText(maxLines: 200) ?? ""
                print("UIPROBE-SERIAL disconnect_banner=false still_connected=\(serialPane?.isConnected == true) tail=\(text.suffix(200))")
            }))
        // Restore-offer: drives the EXACT per-tab restore path with a
        // journaled serial snapshot for an absent device. NOTE (TESTING.md
        // §2.4): this hand-built TabRestore fixture is legitimate here — it
        // is the CONSENT-GATE assertion (never auto-open on restore), not a
        // stand-in for restored-world gesture coverage, which now runs
        // through the real restoreWindows() pipeline in restored mode.
        var restoredSerialController: TerminalWindowController?
        probe.add(ProbeStep(
            name: "serial-restore-offer", timeout: 10,
            action: { [self] in
                let state = SerialAdapter.journalState(
                    path: "/dev/cu.memterm-probe-absent", identity: "usb:0000:0000:probe",
                    label: "probe-restore", settings: SerialSettings(),
                    txLineEnding: .crlf, localEcho: false)
                let snap = SnapshotRow(exe: "", argv: [], adapter: SerialAdapter.name,
                                       adapterState: state)
                let tab = TabRestore(title: "", tree: .pane("probe-serial-restore"),
                                     panes: ["probe-serial-restore":
                                                PaneRestore(cwd: nil, shell: nil, snapshot: snap)])
                let controller = TerminalWindowController(app: self,
                                                          workspaceId: activeWorkspaceId,
                                                          restoredTab: tab)
                registerController(controller)
                let host = makeHost(frame: nil)
                host.attach(controller, select: true)
                host.showWindow(nil)
                host.focusWindow()
                restoredSerialController = controller
            },
            condition: {
                guard let controller = restoredSerialController,
                      let pane = controller.allPanes().first as? SerialPaneView
                else { return false }
                return pane.scrollbackText(maxLines: 100)
                    .contains("was connected: memterm-probe-absent @ 115200-8N1 — press ⌘R to reconnect")
            },
            assert: { [self] in
                guard let controller = restoredSerialController,
                      let pane = controller.allPanes().first as? SerialPaneView else {
                    throw ProbeFailure("serial restore did not build a serial pane")
                }
                print("UIPROBE-SERIAL restore_offer=true auto_opened=\(pane.isConnected) pending=\(pane.pendingReconnectOffer)")
                guard !pane.isConnected, pane.pendingReconnectOffer else {
                    throw ProbeFailure("serial restore offer (consent gate)")
                }
                // ⌘R with the device absent: an honest line, no open.
                typeResumeCommand(nil)
            },
            onFailure: {
                let pane = restoredSerialController?.allPanes().first as? SerialPaneView
                print("UIPROBE-SERIAL restore_offer=false auto_opened=\(pane?.isConnected == true) pending=\(pane?.pendingReconnectOffer == true)")
            }))
        probe.add(ProbeStep(
            name: "serial-reconnect-absent", timeout: 8,
            condition: {
                guard let pane = restoredSerialController?.allPanes().first as? SerialPaneView
                else { return false }
                return pane.scrollbackText(maxLines: 100)
                    .contains("device not connected — memterm-probe-absent @ 115200-8N1")
                    && !pane.isConnected
            },
            assert: {
                print("UIPROBE-SERIAL reconnect_absent=true still_closed=true")
            },
            onFailure: {
                let pane = restoredSerialController?.allPanes().first as? SerialPaneView
                print("UIPROBE-SERIAL reconnect_absent=false still_closed=\(pane?.isConnected == false)")
            }))
    }

    // MARK: - Workspace close + tab gestures (keep-list: FR-56 forget at the
    // gesture, real button/sheet event routing, identity-preserving re-homing)

    private func addWorkspaceCloseSteps(_ probe: ProbeRunner,
                                        probeWorkspaceId: @escaping () -> String?) {
        probe.addStateful(ProbeStep(
            name: "workspace-close-setup", timeout: 8,
            action: { [self] in
                guard let probeWs = probeWorkspaceId() else {
                    probeFail("no Probe workspace (last-tab-close leg)")
                }
                switchToWorkspace(probeWs)
            },
            condition: { [self] in
                guard let probeWs = probeWorkspaceId() else { return false }
                return activeWorkspaceId == probeWs
                    && controllers.contains { $0.workspaceId == probeWs }
            },
            assert: { [self] in
                guard let probeWs = probeWorkspaceId(),
                      memory?.store.listWorkspaces()
                          .contains(where: { $0.id == probeWs }) == true,
                      let doomed = controllers.first(where: { $0.workspaceId == probeWs })
                else { throw ProbeFailure("Probe workspace not presented for last-tab close") }
                doomed.close()  // user close of the workspace's only tab
            }))
        probe.addStateful(ProbeStep(
            name: "workspace-close-surfaces-default", timeout: 8,
            condition: { [self] in
                guard let probeWs = probeWorkspaceId(), let store = memory?.store
                else { return false }
                return !store.listWorkspaces().contains { $0.id == probeWs }
                    && store.listWorkspaces().contains { $0.id == StateStore.defaultWorkspaceId }
                    && activeWorkspaceId == StateStore.defaultWorkspaceId
                    && hosts.contains { $0.window?.isVisible == true }
            },
            assert: { [self] in
                let names = memory?.store.listWorkspaces().map { $0.name } ?? []
                print("UIPROBE-WSCLOSE probe_removed=true default_kept=true surfaced_default=true visible_window=true names=\(names)")
            },
            onFailure: { [self] in
                guard let probeWs = probeWorkspaceId(), let store = memory?.store else { return }
                let list = store.listWorkspaces()
                print("UIPROBE-WSCLOSE probe_removed=\(!list.contains { $0.id == probeWs }) default_kept=\(list.contains { $0.id == StateStore.defaultWorkspaceId }) surfaced_default=\(activeWorkspaceId == StateStore.defaultWorkspaceId) visible_window=\(hosts.contains { $0.window?.isVisible == true }) names=\(list.map { $0.name })")
            }))
    }

    private func addTabGestureSteps(_ probe: ProbeRunner) {
        // Hover-✕: the strip's close button through the REAL button action —
        // a USER close, so FR-56 forgets its rows at the gesture.
        probe.addStateful(ProbeStep(
            name: "hover-x-close", timeout: 8,
            assert: { [self] in
                guard let host = keyHost() else { throw ProbeFailure("no host (close-x leg)") }
                newWindowForTab(nil)
                guard let doomed = host.selectedTab else {
                    throw ProbeFailure("close-x leg: no new tab")
                }
                memory?.flushSync()
                let beforeTabs = memory?.store.counts().tabs ?? -1
                let clicked = host.tabStrip.probeClickClose(of: doomed.tabId)
                memory?.store.barrier()
                let afterTabs = memory?.store.counts().tabs ?? -1
                let forgotten = afterTabs == beforeTabs - 1
                let gone = !controllers.contains { $0 === doomed }
                let stripGone = !host.tabStrip.probeTabIds().contains(doomed.tabId)
                let fr = host.window?.firstResponder as? PaneView
                let focusOK = fr != nil
                    && host.selectedTab?.allPanes().contains { $0 === fr } == true
                print("UIPROBE-CLOSEX clicked=\(clicked) rows_forgotten=\(forgotten) controller_gone=\(gone) strip_gone=\(stripGone) focus_in_pane=\(focusOK)")
                guard clicked, forgotten, gone, stripGone, focusOK else {
                    throw ProbeFailure("hover ✕ must close, forget (FR-56), and return focus to a pane")
                }
            }))

        // Strip double-click rename through the sheet's own controls.
        var renamedTab: TerminalWindowController?
        probe.addStateful(ProbeStep(
            name: "tab-rename-sheet", timeout: 10,
            action: { [self] in
                guard let host = keyHost(), let window = host.window,
                      let tab = host.selectedTab else {
                    probeFail("no host (rename-tab leg)")
                }
                renamedTab = tab
                let doubled = host.tabStrip.probeDoubleClickTab(tab.tabId)
                guard doubled, let sheet = window.attachedSheet,
                      let sheetRoot = sheet.contentView else {
                    probeFail("double-click on the tab did not open the rename sheet")
                }
                func findField(_ view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.isEditable { return field }
                    for sub in view.subviews { if let f = findField(sub) { return f } }
                    return nil
                }
                func findButton(_ view: NSView, title: String) -> NSButton? {
                    if let button = view as? NSButton, button.title == title { return button }
                    for sub in view.subviews {
                        if let b = findButton(sub, title: title) { return b }
                    }
                    return nil
                }
                guard let field = findField(sheetRoot),
                      let rename = findButton(sheetRoot, title: "Rename") else {
                    probeFail("rename sheet lacks its field/button")
                }
                field.stringValue = "Probe-Renamed"
                rename.performClick(nil)
            },
            condition: { renamedTab?.displayTitle == "Probe-Renamed" },
            assert: { [self] in
                guard let tab = renamedTab else { throw ProbeFailure("rename-tab setup lost") }
                memory?.flushSync()
                let journaled = memory?.store
                    .loadState(workspaceId: activeWorkspaceId)
                    .flatMap(\.tabs).contains { $0.title == "Probe-Renamed" } ?? false
                print("UIPROBE-RENAMETAB title=true journaled=\(journaled) display=\(tab.displayTitle)")
                guard journaled else {
                    throw ProbeFailure("strip double-click rename did not pin/journal the title")
                }
                tab.customTitle = nil
            },
            onFailure: {
                print("UIPROBE-RENAMETAB title=false display=\(renamedTab?.displayTitle ?? "nil")")
            }))

        // Move Tab to New Window / Merge All Windows: identity-preserving
        // re-homing — same pane objects, same shell process (kill(pid,0)).
        probe.addStateful(ProbeStep(
            name: "move-merge-windows", timeout: 10,
            assert: { [self] in
                guard let host = hosts.first(where: { h in
                          h.workspaceId == activeWorkspaceId && h.tabs.count > 1
                              && h.tabs.contains {
                                  $0.allPanes().first?.process?.running == true
                              }
                      }),
                      let tab = host.tabs.first(where: {
                          $0.allPanes().first?.process?.running == true
                      }) else {
                    throw ProbeFailure("no multi-tab host with a shell tab (move-window leg)")
                }
                host.focusWindow()
                host.select(tab)
                let paneIds = Set(tab.allPanes().map(ObjectIdentifier.init))
                guard let pid = tab.allPanes().first?.process?.shellPid else {
                    throw ProbeFailure("move-window leg: no shell pid")
                }
                let hostsBefore = hosts.count
                moveTabToNewWindowAction(nil)
                let fresh = tab.host
                let moved = fresh !== host && hosts.count == hostsBefore + 1
                    && fresh?.tabs.count == 1
                let samePanesMoved = Set(tab.allPanes().map(ObjectIdentifier.init)) == paneIds
                mergeAllWindowsAction(nil)
                let mergedHosts = hosts.filter { $0.workspaceId == activeWorkspaceId }
                let merged = mergedHosts.count == 1
                    && (mergedHosts.first?.tabs.count ?? 0) >= 2
                let samePanes = samePanesMoved
                    && Set(tab.allPanes().map(ObjectIdentifier.init)) == paneIds
                let alive = kill(pid, 0) == 0
                print("UIPROBE-MOVEWIN moved=\(moved) merged=\(merged) same_panes=\(samePanes) pid_alive=\(alive)")
                guard moved, merged, samePanes, alive else {
                    throw ProbeFailure("move-to-new-window/merge must re-home the same panes with the process untouched")
                }
            }))
    }
}
