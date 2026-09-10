import AppKit
import MemtermClaudeBrowser
import MemtermCore
import MemtermExtensionKit
import MemtermTimeline
import SwiftTerm

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
                    // Council #9 evidence: the restored ghost with its
                    // (collapsed) divider, as composited on screen.
                    probeCompositedShot(host.window, name: "council9-restored-ghost")
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
                    // Presented = the journal's NORMAL windows; a drop-down
                    // panel row (2026-09-09) restores as a hidden panel host
                    // and is reconciled separately below.
                    let rows = memory?.store.loadState(workspaceId: activeWorkspaceId) ?? []
                    let journalTabs = rows.filter { !$0.isDropdown }.reduce(0) { $0 + $1.tabs.count }
                    let liveTabs = controllers.filter {
                        $0.workspaceId == activeWorkspaceId && $0.host?.isDropdown != true
                    }.count
                    let journalPanelTabs = rows.filter(\.isDropdown).reduce(0) { $0 + $1.tabs.count }
                    let livePanelTabs = hosts.filter { $0.isDropdown && $0.workspaceId == activeWorkspaceId }
                        .reduce(0) { $0 + $1.tabs.count }
                    print("UIPROBE-OBSERVE journal_tabs=\(journalTabs) live_tabs=\(liveTabs) strip_tabs=\(host.tabStrip.probeTabIds().count) panel_tabs=\(journalPanelTabs)/\(livePanelTabs)")
                    guard journalTabs == liveTabs, liveTabs == host.tabStrip.probeTabIds().count else {
                        throw ProbeFailure("presented tabs disagree with the journal on an untouched launch")
                    }
                    guard journalPanelTabs == livePanelTabs else {
                        throw ProbeFailure("drop-down panel rows (\(journalPanelTabs)) disagree with the restored panel (\(livePanelTabs))")
                    }
                }))
            // Stage 3: READ-ONLY check of the claude scanner against the
            // REAL ~/.claude (founder rule: reading is allowed for real-data
            // verification; nothing may be modified). Runs in the observe
            // quarantine — the run that creates and forces nothing.
            probe.add(ProbeStep(
                name: "observe-claude-real",
                assert: { [self] in
                    let projectsDir = Adapters.defaultClaudeProjectsDir
                    guard FileManager.default.fileExists(atPath: projectsDir.path) else {
                        probe.skipLine(step: "observe-claude-real",
                                       reason: "no ~/.claude/projects on this machine")
                        return
                    }
                    // List through the KIT surface (the browser's own path).
                    guard let host = extensionRuntime?.host else {
                        throw ProbeFailure("no extension host runtime")
                    }
                    let projects = host.claude.projects()
                    guard !projects.isEmpty else {
                        throw ProbeFailure("real ~/.claude/projects listed zero projects")
                    }
                    let totalSessions = projects.reduce(0) { $0 + $1.sessionCount }
                    guard totalSessions > 0 else {
                        throw ProbeFailure("real ~/.claude holds no sessions")
                    }
                    // mtime half: proved on the LEAST recently active project
                    // — a live foreign claude (this very agent, likely) is
                    // writing the newest project's jsonl right now, so its
                    // mtimes move without us; the oldest project's cannot.
                    func mtimes(under dir: URL) -> [String: Date] {
                        var map: [String: Date] = [:]
                        let attrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
                        map[dir.path] = attrs?[.modificationDate] as? Date
                        let files = (try? FileManager.default.contentsOfDirectory(
                            at: dir, includingPropertiesForKeys: nil)) ?? []
                        for file in files {
                            let a = try? FileManager.default.attributesOfItem(atPath: file.path)
                            map[file.path] = a?[.modificationDate] as? Date
                        }
                        return map
                    }
                    guard let coldest = projects.last(where: { $0.sessionCount > 0 }) else {
                        throw ProbeFailure("no project with sessions to scan")
                    }
                    let coldDir = projectsDir.appendingPathComponent(coldest.slug)
                    let before = mtimes(under: coldDir)
                    // Full-detail scans: the coldest project (mtime-gated)
                    // AND the newest (real live-session coverage; not gated).
                    let coldSessions = host.claude.sessions(coldest)
                    let hotSessions = host.claude.sessions(projects[0])
                    for session in coldSessions + hotSessions {
                        guard Adapters.isValidClaudeSessionId(session.id.raw) else {
                            throw ProbeFailure("scan surfaced an invalid session id \(session.id.raw)")
                        }
                    }
                    guard !coldSessions.isEmpty else {
                        throw ProbeFailure("coldest project scan returned no sessions despite count \(coldest.sessionCount)")
                    }
                    let after = mtimes(under: coldDir)
                    guard before == after else {
                        throw ProbeFailure("mtimes changed under \(coldDir.lastPathComponent) — a read-only scan wrote something")
                    }
                    print("UIPROBE-OBSERVE-CLAUDE projects=\(projects.count) total_sessions=\(totalSessions) cold_scanned=\(coldSessions.count) hot_scanned=\(hotSessions.count) mtimes_unchanged=true")
                }))
            return  // observe registers no gesture steps, by construction
        }

        // ---------------------------------------------------------------
        // Fixtures for the gesture legs. In a restored run these ADD to the
        // restored world (which step 1 already certified untouched).
        // ---------------------------------------------------------------
        var probeWorkspaceId: String?
        // The KEY host's own tab count: a restored world may also carry a
        // hidden drop-down panel whose tab is a controller but not in this
        // strip (2026-09-09).
        let tabsAtLaunch = keyHost()?.tabs.count ?? controllers.count
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
        // Step: chip-vertical-centering — founder screenshot (2026-09-01):
        // chip content rode LOW in the pill. Gated on RENDERED PIXELS, not
        // a constraint eyeball: sample each chip's region of the bar
        // bitmap, compute the content bounding box (dot + label glyphs;
        // the hover ✕ is alpha 0), and assert its vertical center sits on
        // the chip's own center within tolerance. Frame half: each chip's
        // 19pt pill is centered in the bar's optical band — the 25pt above
        // the 1pt bottom hairline (the old stack offset rode 0.5pt LOW:
        // AppKit centerY constants are positive-down).
        // ---------------------------------------------------------------
        probe.add(ProbeStep(
            name: "chip-vertical-centering",
            assert: { [self] in
                guard config.workspaceBar else {
                    probe.skipLine(step: "chip-vertical-centering",
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
                // Optical mid of the bar: the band ABOVE the 1pt bottom
                // separator hairline.
                let opticalMidY = (bar.bounds.height + 1) / 2
                var measured = 0
                for (id, frame) in chips {
                    let frameOff = frame.midY - opticalMidY
                    guard abs(frameOff) <= 0.5 else {
                        throw ProbeFailure("chip \(id.prefix(8)) pill off-center in the bar: midY=\(frame.midY) optical=\(opticalMidY)")
                    }
                    // Parked chips: the dimmed size-9 "(parked)" suffix's
                    // parens/descender legitimately extend below the shared
                    // baseline (restored worlds carry a parked B), so the
                    // rendered-band assertion measures normal chips only —
                    // their frame centering was asserted above.
                    guard !bar.probeChipIsParked(id) else {
                        print("UIPROBE-CHIP-CENTER id=\(id.prefix(8)) parked=true frame_off=\(String(format: "%.2f", frameOff)) content_band=skipped")
                        continue
                    }
                    measured += 1
                    guard let content = probeContentBoundingBox(bmp, region: frame) else {
                        throw ProbeFailure("chip \(id.prefix(8)) region has no content pixels")
                    }
                    let contentOff = content.midY - frame.midY
                    // Per-part diagnostics: the label's own glyph band and
                    // the dot region, so a failure names WHICH part rides.
                    if let labelFrame = bar.probeChipLabelFrames()
                        .first(where: { $0.id == id })?.frame,
                       let glyphs = probeContentBoundingBox(bmp, region: labelFrame) {
                        let dotRegion = CGRect(x: frame.minX, y: frame.minY,
                                               width: labelFrame.minX - frame.minX,
                                               height: frame.height)
                        let dot = probeContentBoundingBox(bmp, region: dotRegion)
                        print("UIPROBE-CHIP-CENTER-PARTS id=\(id.prefix(8)) label_frame_mid=\(String(format: "%.2f", labelFrame.midY)) glyph_mid=\(String(format: "%.2f", glyphs.midY)) glyph_box=\(Int(glyphs.minY))..\(String(format: "%.1f", glyphs.maxY)) dot_mid=\(dot.map { String(format: "%.2f", $0.midY) } ?? "nil")")
                    }
                    print("UIPROBE-CHIP-CENTER id=\(id.prefix(8)) chip_mid=\(String(format: "%.2f", frame.midY)) content_mid=\(String(format: "%.2f", content.midY)) content_off=\(String(format: "%.2f", contentOff)) frame_off=\(String(format: "%.2f", frameOff))")
                    // 0.75pt: strictly below the 1.0pt ride the founder's
                    // screenshot showed (and the frame-centered label's
                    // measured regression state), above pixel/AA noise.
                    guard abs(contentOff) <= 0.75 else {
                        probeScreenshot(bar, name: "chip-centering-fail")
                        throw ProbeFailure("chip \(id.prefix(8)) content rides \(contentOff < 0 ? "low" : "high") by \(String(format: "%.2f", abs(contentOff)))pt (tolerance 0.75)")
                    }
                }
                guard measured >= 1 else {
                    throw ProbeFailure("no non-parked chip to measure — the centering gate would be vacuous")
                }
                print("UIPROBE-CHIPS centering_ok=true chips=\(chips.count) measured=\(measured)")
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

        // Settings 2.0: the sectioned window must construct and load — and
        // (council #5) size PER SECTION at a fixed 560pt width: the Memory
        // path middle-truncates instead of stretching the window, and
        // switching sections resizes instead of staying stretched.
        probe.add(ProbeStep(
            name: "settings-window-builds",
            assert: { [self] in
                let settings = SettingsWindowController(app: self)
                print("UIPROBE-SETTINGS built=\(settings.window != nil)")
                guard settings.window != nil else {
                    throw ProbeFailure("settings window did not build")
                }
                var heights: [String: CGFloat] = [:]
                for section in ["General", "Appearance", "Terminal", "Memory"] {
                    settings.probeSelectSection(section)
                    let size = settings.probeContentSize
                    heights[section] = size.height
                    guard abs(size.width - 560) <= 0.5 else {
                        throw ProbeFailure("\(section) section stretched the window to \(size.width)pt wide")
                    }
                }
                let distinct = Set(heights.values.map { Int($0.rounded()) })
                print("UIPROBE-SETTINGS heights=\(heights.mapValues { Int($0) }) per_section=\(distinct.count > 1) path_truncates=\(settings.probeDiskUsageTruncatesMiddle) opacity_readout=\(settings.probeOpacityReadout)")
                guard distinct.count > 1 else {
                    throw ProbeFailure("window height identical across sections — not sizing per section")
                }
                guard settings.probeDiskUsageTruncatesMiddle else {
                    throw ProbeFailure("state-dir path does not middle-truncate")
                }
                guard settings.probeOpacityReadout.range(
                    of: #"^([0-9]+%|Opaque)$"#, options: .regularExpression) != nil else {
                    throw ProbeFailure("transparency readout reads \"\(settings.probeOpacityReadout)\"")
                }
                if ProbeSupport.visible, let win = settings.window {
                    // Council #5 evidence: the Memory section as composited
                    // (the loop above leaves Memory selected).
                    win.center()
                    win.orderFront(nil)
                    win.contentView?.layoutSubtreeIfNeeded()
                    win.displayIfNeeded()
                    probeCompositedShot(win, name: "council5-settings-memory")
                    win.orderOut(nil)
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
        // Chip click gate (founder polish 2026-09-01): rename is DOUBLE-CLICK
        // ONLY. Driven through the chip's REAL mouseDown with synthesized
        // events (gesture fidelity — the rename legs above enter via
        // beginWorkspaceRename and cannot see the click routing): a single
        // click on the ACTIVE chip must be a no-op (no editor, no switch), a
        // double click must open the inline editor.
        // ---------------------------------------------------------------
        var chipClickSingleOpened = true   // pessimistic until measured
        var chipClickDoubleOpened = false
        probe.add(ProbeStep(
            name: "chip-click-rename-gate", timeout: 8,
            action: { [self] in
                guard config.workspaceBar else { return }
                guard let host = keyHost(), let bar = host.workspaceBar,
                      let chip = bar.probeChipView(activeWorkspaceId) else {
                    probeFail("chip-click leg: no active workspace chip")
                }
                renameHost = host
                let center = NSPoint(x: chip.bounds.midX, y: chip.bounds.midY)
                guard let single = probeMouseEvent(.leftMouseDown, in: chip,
                                                   at: center, clickCount: 1),
                      let double = probeMouseEvent(.leftMouseDown, in: chip,
                                                   at: center, clickCount: 2) else {
                    probeFail("chip-click leg: could not synthesize events")
                }
                let wsBefore = activeWorkspaceId
                chip.mouseDown(with: single)
                chipClickSingleOpened = chip.probeIsEditing
                if chipClickSingleOpened {
                    probeFail("single click on the active chip opened the rename editor")
                }
                if activeWorkspaceId != wsBefore {
                    probeFail("single click on the active chip switched workspaces")
                }
                chip.mouseDown(with: double)
                chipClickDoubleOpened = chip.probeIsEditing
                guard chipClickDoubleOpened,
                      let editor = host.window?.firstResponder as? NSTextView else {
                    probeFail("double click on the active chip did not open the inline editor (editing=\(chipClickDoubleOpened))")
                }
                // Cancel through the real field-editor path; the condition
                // rides the focus handoff back to the pane.
                editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            },
            condition: { [self] in
                !config.workspaceBar || (renameHost?.window?.firstResponder is PaneView)
            },
            assert: { [self] in
                guard config.workspaceBar else {
                    probe.skipLine(step: "chip-click-rename-gate", reason: "workspace_bar=false")
                    return
                }
                print("UIPROBE-CHIPCLICK single_opened_editor=\(chipClickSingleOpened) double_opened_editor=\(chipClickDoubleOpened) focus_back_to_pane=true")
            },
            onFailure: {
                print("UIPROBE-CHIPCLICK single_opened_editor=\(chipClickSingleOpened) double_opened_editor=\(chipClickDoubleOpened) fr=\(String(describing: renameHost?.window?.firstResponder))")
            }))

        // ---------------------------------------------------------------
        // Random workspace colors (founder polish 2026-09-01): every NEW
        // workspace draws a preset no existing workspace is using — repeats
        // are legal only once all six presets are taken. Exercises the REAL
        // createWorkspace draw (the pure candidate math is L1-tested in
        // WorkspaceColorPickTests); world restored via the FR-50/57 forget
        // path afterwards.
        // ---------------------------------------------------------------
        probe.add(ProbeStep(
            name: "workspace-random-colors",
            assert: { [self] in
                guard let store = memory?.store else {
                    throw ProbeFailure("no store (random-colors leg)")
                }
                let presets = Set(Self.workspaceColorPresets.map(\.hex))
                var created: [String] = []
                var drawn: [String] = []
                defer { for id in created { forgetWorkspace(id) } }
                for i in 1...3 {
                    let usedBefore = store.listWorkspaces().map(\.color)
                    let unused = presets.subtracting(usedBefore)
                    guard let id = createWorkspace(named: "ColorProbe-\(i)") else {
                        throw ProbeFailure("createWorkspace failed (random-colors leg)")
                    }
                    created.append(id)
                    guard let color = store.listWorkspaces()
                        .first(where: { $0.id == id })?.color else {
                        throw ProbeFailure("created workspace has no color row")
                    }
                    drawn.append(color)
                    guard presets.contains(color) else {
                        throw ProbeFailure("workspace color \(color) is not one of the 6 presets")
                    }
                    if !unused.isEmpty, !unused.contains(color) {
                        throw ProbeFailure("workspace color \(color) repeats a used preset while \(unused.count) presets were still free (used=\(usedBefore))")
                    }
                }
                print("UIPROBE-WSCOLORS drawn=\(drawn) all_presets=true no_repeat_while_free=true")
            }))

        // ---------------------------------------------------------------
        // Fullscreen. Quiet mode asserts the chrome across a frame
        // transition instead of driving a real Spaces animation (§2.5);
        // MEMTERM_PROBE_VISIBLE=1 keeps the real round-trip.
        // ---------------------------------------------------------------
        if ProbeSupport.visible {
            var fsEntered = false
            var fsEnterObserver: NSObjectProtocol?
            probe.add(ProbeStep(
                name: "fullscreen-enter", timeout: 10,
                action: { [self] in
                    guard let window = keyHost()?.window else { return }
                    // Track the END of the enter transition: the exit leg
                    // must not toggle mid-transition (AppKit drops it —
                    // visible-run flake on the founder's 7680-wide display).
                    fsEntered = false
                    fsEnterObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.didEnterFullScreenNotification, object: window,
                        queue: .main) { _ in fsEntered = true }
                    window.toggleFullScreen(nil)
                },
                condition: { [self] in
                    keyHost()?.window?.styleMask.contains(.fullScreen) == true
                },
                assert: { [self] in
                    let height = keyHost()?.window?.frame.height ?? 0
                    print("UIPROBE-FS entered=true frame_h=\(Int(height))")
                },
                onFailure: { print("UIPROBE-FS entered=false") }))
            probe.add(ProbeStep(
                name: "fullscreen-exit", timeout: 15,
                action: { [self] in
                    // Leave only once the enter transition has COMPLETED
                    // (didEnterFullScreen), plus a beat; poll for it rather
                    // than toggling on a clock.
                    func leaveWhenEntered(attempt: Int = 0) {
                        if fsEntered || attempt >= 40 {
                            if let observer = fsEnterObserver {
                                NotificationCenter.default.removeObserver(observer)
                                fsEnterObserver = nil
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                self.keyHost()?.window?.toggleFullScreen(nil)
                            }
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                leaveWhenEntered(attempt: attempt + 1)
                            }
                        }
                    }
                    leaveWhenEntered()
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

        addChromeCoherenceSteps(probe)
        addCouncilStage2Steps(probe)
        addWorkspaceSheetSteps(probe)
        addClosePaneSteps(probe, mode: mode)
        addScrollUXSteps(probe)
        addSerialSteps(probe)
        addWorkspaceCloseSteps(probe, probeWorkspaceId: { probeWorkspaceId })
        addTabGestureSteps(probe)
        addClaudeBrowserSteps(probe)
        // Quake-style drop-down legs: before the archive legs (which wipe
        // the probe state dir last by design).
        addDropdownSteps(probe)
        // LAST gesture legs by design: forget-everything-empties-archive
        // wipes the probe state dir's memory (isolated by MEMTERM_STATE_DIR;
        // both refuse-real-state-dir belts hold), so nothing may run after it
        // that depends on captured state.
        addArchiveSteps(probe)
        addDropdownAfterCloseAllSteps(probe)

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

    // -----------------------------------------------------------------
    // Council #2 + #3 (2026-09-02 polish sprint): chrome-vs-theme coherence
    // and the terminal-content inset, both gated on presented reality.
    // -----------------------------------------------------------------
    private func addChromeCoherenceSteps(_ probe: ProbeRunner) {
        // Chrome follows the theme: the window appearance is keyed from the
        // theme ground (ChromeContrast.prefersLightChrome — L2-tested), the
        // RENDERED strip ground lives in the same light/dark world as the
        // theme background, and the selected tab's label text is legible on
        // it. verify.sh runs this across the config matrix (light / dark /
        // founder-like), which is what makes "two apps stacked" a red gate.
        probe.add(ProbeStep(
            name: "chrome-theme-coherence",
            assert: { [self] in
                guard let host = keyHost(), let window = host.window,
                      let strip = host.tabStrip else {
                    throw ProbeFailure("no host/strip (chrome-coherence leg)")
                }
                let themeBg = config.themeBackgroundColor ?? .black
                let expectLight = ChromeContrast.prefersLightChrome(
                    themeBackground: config.themeBackground)
                let appearance = window.effectiveAppearance
                    .bestMatch(from: [.aqua, .darkAqua])
                guard (appearance == .aqua) == expectLight else {
                    throw ProbeFailure("window appearance \(String(describing: appearance)) disagrees with theme ground (light=\(expectLight))")
                }
                strip.layoutSubtreeIfNeeded()
                guard let bmp = probeBitmap(strip) else {
                    throw ProbeFailure("tab strip produced no bitmap")
                }
                // Rendered ground: an empty strip region (clear of tabs, the
                // + button, and the gear that docks at the far right when the
                // workspace bar is hidden).
                let ground = NSRect(x: strip.bounds.maxX - 90, y: 6,
                                    width: 50, height: strip.bounds.height - 10)
                guard let groundColor = probeDominantColor(bmp, region: ground) else {
                    throw ProbeFailure("no strip ground samples")
                }
                let groundLum = probeLuminance(groundColor)
                let themeLum = probeLuminance(themeBg)
                let sameWorld = (groundLum > 0.5) == (themeLum > 0.5)
                // Label text half: the selected tab's label region renders
                // visibly against that ground.
                guard let selectedId = host.selectedTab?.tabId,
                      let labelFrame = strip.probeLabelFrame(of: selectedId) else {
                    throw ProbeFailure("no selected tab label frame")
                }
                try assertChipVisible(chipFrame: labelFrame, in: bmp,
                                      what: "selected tab label")
                print("UIPROBE-CHROME theme_lum=\(String(format: "%.2f", themeLum)) ground_lum=\(String(format: "%.2f", groundLum)) appearance=\(expectLight ? "aqua" : "darkAqua") same_world=\(sameWorld)")
                guard sameWorld else {
                    throw ProbeFailure("chrome ground (lum \(groundLum)) and theme ground (lum \(themeLum)) live in different worlds — the 'two apps stacked' bug")
                }
                if let shot = probeScreenshot(strip, name: "chrome-theme-\(expectLight ? "light" : "dark")") {
                    print("UIPROBE-CHROME screenshot=\(shot)")
                }
                probeCompositedShot(window,
                                    name: "council2-chrome-\(expectLight ? "light" : "dark")")
            }))

        // Council #3: the tab's pane tree sits inset from the window edges —
        // live and ghost content get breathing room; splits divide the inset
        // region so dividers stay correct. Stateful: the restored world must
        // present the same margins (its tree is built by buildNode).
        probe.addStateful(ProbeStep(
            name: "content-inset",
            assert: { [self] in
                guard let host = keyHost(), let tab = host.selectedTab,
                      let root = tab.paneRoot.subviews.first else {
                    throw ProbeFailure("no pane tree (content-inset leg)")
                }
                host.window?.contentView?.layoutSubtreeIfNeeded()
                let expected = tab.paneRoot.bounds.insetBy(
                    dx: SplitLayout.contentInset, dy: SplitLayout.contentInset)
                let f = root.frame
                let offBy = max(abs(f.minX - expected.minX), abs(f.minY - expected.minY),
                                abs(f.maxX - expected.maxX), abs(f.maxY - expected.maxY))
                print("UIPROBE-INSET root=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)) container=\(Int(tab.paneRoot.bounds.width))x\(Int(tab.paneRoot.bounds.height)) off_by=\(String(format: "%.1f", offBy))")
                guard offBy <= 1.5 else {
                    throw ProbeFailure("pane tree not inset \(Int(SplitLayout.contentInset))pt from the container (off by \(offBy))")
                }
                probeCompositedShot(host.window, name: "council3-content-inset")
            }))

        // Founder bug 2026-09-09 ("this weird bar or border around the whole
        // text area"): under window_opacity < 1 the pane painted the theme
        // ground AGAIN over the window's, so the council-#3 margin (one
        // layer) read lighter than the pane body (two). Two truths:
        //   * model (every run): exactly ONE layer carries the alpha — the
        //     window ground at window_opacity, the pane ground at 0.
        //   * composited pixels (visible runs, screen-capture permitted):
        //     a margin sample and an adjacent blank pane-interior sample
        //     match on screen. (cacheDisplay bitmaps omit layer grounds —
        //     calibrated: they read 0/0/0 a0 with AND without the bug.)
        // Opaque configs skip (the seam only exists under translucency).
        probe.add(ProbeStep(
            name: "translucent-ground-seam",
            assert: { [self] in
                guard !config.isWindowOpaque else {
                    probe.skipLine(step: "translucent-ground-seam",
                                   reason: "window_opacity=1")
                    return
                }
                guard let host = keyHost(), let window = host.window,
                      let tab = host.selectedTab, let pane = tab.allPanes().first else {
                    throw ProbeFailure("no pane (seam leg)")
                }
                window.contentView?.layoutSubtreeIfNeeded()
                // The engine paints its ground from nativeBackgroundColor (its
                // layer color is a stale init-time copy — calibrated: it read
                // 0 with AND without the bug), so gate on the property itself.
                let paneAlpha = pane.nativeBackgroundColor.alphaComponent
                let windowAlpha = window.backgroundColor.alphaComponent
                // Founder 2026-09-09 ("why does the black background stand
                // out so much"): explicit cell backgrounds follow the window
                // opacity (iTerm2-style) — the fork's translucentCellBackgrounds
                // must be on, and a red-background cell must map to the
                // window's alpha, not a solid block.
                // (The per-cell alpha itself is pinned by the fork's own
                // BackgroundOpacityTests; the mapping is internal to SwiftTerm.)
                let cellsFollow = pane.translucentCellBackgrounds
                let modelOk = paneAlpha <= 0.01
                    && abs(windowAlpha - config.effectiveOpacity) <= 0.01
                    && cellsFollow
                print("UIPROBE-SEAM-MODEL opacity=\(config.windowOpacity) pane_alpha=\(String(format: "%.2f", paneAlpha)) window_alpha=\(String(format: "%.2f", windowAlpha)) cells_follow_opacity=\(cellsFollow) ok=\(modelOk)")
                guard modelOk else {
                    throw ProbeFailure("translucent ground model broken: pane alpha \(String(format: "%.2f", paneAlpha)), window alpha \(String(format: "%.2f", windowAlpha)), explicit cell backgrounds follow opacity: \(cellsFollow)")
                }
                guard ProbeSupport.visible else { return }
                guard let bmp = probeCompositedBitmap(window, name: "translucent-seam") else {
                    print("UIPROBE-SEAM-PIXELS skipped=no-composited-capture")
                    return
                }
                let root = tab.paneRoot
                let paneInRoot = pane.convert(pane.bounds, to: root)
                // Adjacent samples near the container's bottom-left (the
                // prompt lives top-left; blur makes the desktop behind two
                // neighbouring bands near-identical): the left margin band,
                // and the pane interior just inside it.
                let yBand = root.bounds.minY + 24
                let margin = root.convert(CGRect(x: 1, y: yBand,
                                                 width: SplitLayout.contentInset - 2,
                                                 height: 14), to: nil)
                let interior = root.convert(CGRect(x: paneInRoot.minX + 3, y: yBand,
                                                   width: 24, height: 14), to: nil)
                func mean(_ region: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat, n: Int) {
                    let sx = CGFloat(bmp.pixelsWide) / max(window.frame.width, 1)
                    let sy = CGFloat(bmp.pixelsHigh) / max(window.frame.height, 1)
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
                    var n = 0
                    for i in 0..<8 {
                        for j in 0..<4 {
                            let vx = region.minX + region.width * (CGFloat(i) + 0.5) / 8
                            let vy = region.minY + region.height * (CGFloat(j) + 0.5) / 4
                            let px = Int(vx * sx), py = Int((window.frame.height - vy) * sy)
                            guard px >= 0, py >= 0, px < bmp.pixelsWide, py < bmp.pixelsHigh,
                                  let c = bmp.colorAt(x: px, y: py)?.usingColorSpace(.sRGB)
                            else { continue }
                            r += c.redComponent; g += c.greenComponent; b += c.blueComponent
                            n += 1
                        }
                    }
                    let d = CGFloat(max(n, 1))
                    return (r / d, g / d, b / d, n)
                }
                let m = mean(margin), q = mean(interior)
                guard m.n > 0, q.n > 0 else {
                    throw ProbeFailure("seam samples outside the composited image")
                }
                let delta = max(abs(m.r - q.r), abs(m.g - q.g), abs(m.b - q.b))
                let match = delta <= 0.06
                print("UIPROBE-SEAM-PIXELS opacity=\(config.windowOpacity) margin=\(String(format: "%.2f/%.2f/%.2f", m.r, m.g, m.b)) interior=\(String(format: "%.2f/%.2f/%.2f", q.r, q.g, q.b)) delta=\(String(format: "%.3f", delta)) match=\(match)")
                guard match else {
                    probeCompositedShot(window, name: "translucent-seam-fail")
                    throw ProbeFailure("translucent ground seam on screen: margin vs pane interior differ by \(String(format: "%.3f", delta))")
                }
            }))

        // Founder bug 2026-09-09 (ghost "Theexitcodecamefromthelastls"): a
        // renderer that skips space runs with cursor-forward leaves
        // never-written cells; the LIVE capture surface must serialize them
        // as spaces, never NUL. Display-only feed into the pane — nothing
        // reaches the pty.
        probe.add(ProbeStep(
            name: "capture-skipped-cells",
            assert: { [self] in
                guard let host = keyHost(), let tab = host.selectedTab,
                      let pane = tab.allPanes().first else {
                    throw ProbeFailure("no pane (capture-cells leg)")
                }
                pane.feed(text: "\r\nprobe-gap\u{1b}[3Ccells\u{1b}[2Cend\r\n")
                let text = pane.scrollbackText(maxLines: 200)
                let hasNul = text.contains("\0")
                let hasGap = text.contains("probe-gap   cells  end")
                print("UIPROBE-CAPTURE-CELLS gap_ok=\(hasGap) nul=\(hasNul)")
                guard hasGap, !hasNul else {
                    throw ProbeFailure("capture lost skipped cells: gap_ok=\(hasGap) nul=\(hasNul)")
                }
            }))
    }

    // -----------------------------------------------------------------
    // Council stage 2 (2026-09-02): the seven detail items, gated where
    // each one's truth lives — layout math mirrored by the strip (#4),
    // menu structure + validation (#6), the find bar's counter and calm
    // affordances (#7), the theme-derived divider on rendered pixels
    // (#8), and the chips-below-pills visual hierarchy (#10).
    // -----------------------------------------------------------------
    // swiftlint:disable:next function_body_length
    private func addCouncilStage2Steps(_ probe: ProbeRunner) {

        // #4: tabs use the strip width — the strip's presented widths obey
        // TabStripLayout (360pt cap), and a long host:path title truncates
        // in the MIDDLE, keeping the leaf visible.
        probe.addStateful(ProbeStep(
            name: "tab-width-and-truncation",
            assert: { [self] in
                guard let host = keyHost(), let strip = host.tabStrip,
                      let selected = host.selectedTab else {
                    throw ProbeFailure("no strip (tab-width leg)")
                }
                strip.layoutSubtreeIfNeeded()
                let ids = strip.probeTabIds()
                guard let firstId = ids.first,
                      let frame = strip.probeItemFrame(of: firstId) else {
                    throw ProbeFailure("no strip items (tab-width leg)")
                }
                guard frame.width <= CGFloat(TabStripLayout.maxTabWidth) + 0.5 else {
                    throw ProbeFailure("tab width \(frame.width) exceeds the \(TabStripLayout.maxTabWidth)pt cap")
                }
                // With few tabs in a ~980pt window the tabs must actually USE
                // the room — wider than the old 220 cap.
                if ids.count <= 2, strip.bounds.width >= 800 {
                    guard frame.width > 220 else {
                        throw ProbeFailure("tab width \(frame.width) stuck at the old 220 cap with room to grow")
                    }
                }
                let longTitle = "user@buildhost:/very/deep/project/tree/memterm/Sources/memterm"
                selected.customTitle = longTitle
                let lineBreak = strip.probeLabelLineBreak(of: selected.tabId)
                strip.layoutSubtreeIfNeeded()
                strip.displayIfNeeded()
                probeCompositedShot(host.window, name: "council4-tab-truncation")
                selected.customTitle = nil
                print("UIPROBE-TABWIDTH width=\(Int(frame.width)) cap=\(Int(TabStripLayout.maxTabWidth)) tabs=\(ids.count) middle_truncates=\(lineBreak == .byTruncatingMiddle)")
                guard lineBreak == .byTruncatingMiddle else {
                    throw ProbeFailure("long titles do not middle-truncate")
                }
            }))

        // #6: menu hygiene — structure (Services, Help, Actual Size, Enter
        // Full Screen, Use Selection for Find) and honest validation (⌘1–9
        // against the tab count, Close Pane/Tab dynamic title).
        probe.add(ProbeStep(
            name: "menu-hygiene",
            assert: { [self] in
                guard let main = NSApp.mainMenu else { throw ProbeFailure("no main menu") }
                func item(_ menuTitle: String, _ itemTitle: String) -> NSMenuItem? {
                    main.items.first { $0.title == menuTitle }?.submenu?.items
                        .first { $0.title == itemTitle }
                }
                guard NSApp.servicesMenu != nil,
                      item("memterm", "Services")?.submenu === NSApp.servicesMenu else {
                    throw ProbeFailure("Services submenu missing/unregistered")
                }
                guard let help = NSApp.helpMenu,
                      help.items.contains(where: { $0.title == "memterm README" }),
                      help.items.contains(where: { $0.title == "About memterm" }) else {
                    throw ProbeFailure("Help menu (About + README) missing")
                }
                guard let actual = item("View", "Actual Size"),
                      actual.keyEquivalent == "0",
                      actual.action == #selector(resetFontSize(_:)) else {
                    throw ProbeFailure("View ▸ Actual Size (⌘0) missing")
                }
                let viewItems = main.items.first { $0.title == "View" }?.submenu?.items ?? []
                let fsItems = viewItems.filter {
                    $0.action == #selector(NSWindow.toggleFullScreen(_:))
                }
                // AppKit adopts the item: it hides our ⌃⌘F declaration and
                // manages the platform-current shortcut pair itself
                // (live-verified: visible Globe-F + hidden variants). One
                // VISIBLE item is the no-duplicate-affordances contract.
                let visibleFS = fsItems.filter { !$0.isHidden }
                guard !fsItems.isEmpty, visibleFS.count == 1 else {
                    throw ProbeFailure("View ▸ Enter Full Screen: \(visibleFS.count) visible of \(fsItems.count) item(s) — want exactly one visible")
                }
                guard let find = item("Edit", "Find")?.submenu?.items
                        .first(where: { $0.title == "Use Selection for Find" }),
                      find.keyEquivalent == "e" else {
                    throw ProbeFailure("Edit ▸ Find ▸ Use Selection for Find (⌘E) missing")
                }
                // Validation half — driven through the REAL validateMenuItem.
                let tabCount = keyHost()?.tabs.count ?? 0
                func tabItem(_ tag: Int) -> NSMenuItem {
                    let it = NSMenuItem(title: "Tab \(tag)",
                                        action: #selector(selectTab(_:)), keyEquivalent: "")
                    it.tag = tag
                    return it
                }
                let inRange = tabCount < 1 || validateMenuItem(tabItem(1))
                // The first ⌘n beyond the tab count must validate OFF
                // (only meaningful while a Tab-n item exists for it, n ≤ 8).
                let outValid = tabCount + 1 <= 8
                    ? validateMenuItem(tabItem(tabCount + 1)) : false
                let lastTab = validateMenuItem(tabItem(9))
                let closeItem = NSMenuItem(title: "Close Tab",
                                           action: #selector(closePane(_:)), keyEquivalent: "")
                _ = validateMenuItem(closeItem)
                let expectedClose = (keyController()?.allPanes().count ?? 1) > 1
                    ? "Close Pane" : "Close Tab"
                print("UIPROBE-MENU tabs=\(tabCount) in_range=\(inRange) beyond_count_valid=\(outValid) last_tab=\(lastTab) close_title=\(closeItem.title) expected=\(expectedClose)")
                guard inRange, !outValid, lastTab == (tabCount > 1),
                      closeItem.title == expectedClose else {
                    throw ProbeFailure("menu validation dishonest (tabs=\(tabCount) in=\(inRange) beyond=\(outValid) last=\(lastTab) close=\(closeItem.title))")
                }
            }))

        // #7: the find bar counts honestly ("N of M"), closes calmly
        // (borderless ✕), and the regex toggle says what it is (".*").
        var findPane: PaneView?
        probe.addStateful(ProbeStep(
            name: "find-bar-count", timeout: 10,
            action: { [self] in
                guard let pane = keyController()?.currentPane() else {
                    probeFail("no pane (find-bar leg)")
                }
                findPane = pane
                pane.feed(text: "needle one needle two needle\r\n")
                pane.openFindBar()
                pane.findBar?.searchText = "needle"
                pane.findBarSearchChanged("needle")
            },
            condition: {
                // Re-run until the fed bytes are through the terminal parser.
                guard let pane = findPane, let bar = pane.findBar else { return false }
                if bar.probeMatchText.contains(" of ") { return true }
                pane.findBarSearchChanged("needle")
                return false
            },
            assert: { [self] in
                guard let pane = findPane, let bar = pane.findBar else {
                    throw ProbeFailure("find bar vanished")
                }
                let label = bar.probeMatchText
                let shape = label.range(of: #"^[0-9]+ of [0-9]+\+?$"#,
                                        options: .regularExpression) != nil
                print("UIPROBE-FIND label=\"\(label)\" shape_ok=\(shape) regex_glyph=\"\(bar.probeRegexTitle)\" close_borderless=\(bar.probeCloseIsBorderless)")
                guard shape else {
                    throw ProbeFailure("match counter reads \"\(label)\", not \"N of M\"")
                }
                guard bar.probeRegexTitle == ".*",
                      bar.probeRegexTooltip == "Regular Expression" else {
                    throw ProbeFailure("regex toggle glyph/tooltip wrong (\(bar.probeRegexTitle) / \(bar.probeRegexTooltip))")
                }
                guard bar.probeCloseIsBorderless else {
                    throw ProbeFailure("find-bar close is still a bezeled button")
                }
                pane.closeFindBar()
                guard keyHost()?.window?.firstResponder === pane else {
                    throw ProbeFailure("closing the find bar did not return focus to the pane")
                }
            }))

        // #8: the split divider is VISIBLE on this config's theme ground —
        // model half (the derived color clears the L2 floor) and rendered
        // half (the divider's pixels contrast against the pane ground).
        // verify.sh runs this across the matrix — the dark variant is the
        // world the founder bug lived in.
        var dividerPane: PaneView?
        probe.addStateful(ProbeStep(
            name: "divider-theme-contrast", timeout: 12,
            action: { [self] in
                guard let controller = keyController() else {
                    probeFail("no controller (divider leg)")
                }
                let before = controller.allPanes()
                controller.splitCurrentPane(vertical: true)
                dividerPane = controller.allPanes().first { pane in
                    !before.contains { $0 === pane }
                }
            },
            condition: { dividerPane?.process?.running == true },
            assert: { [self] in
                guard let controller = keyController(),
                      let split = controller.allSplitViews().first,
                      split.arrangedSubviews.count == 2 else {
                    throw ProbeFailure("no split (divider leg)")
                }
                let themeBg = config.themeBackgroundColor ?? .black
                let modelRatio = contrastRatio(split.themeDividerColor, themeBg)
                split.window?.contentView?.layoutSubtreeIfNeeded()
                guard let bmp = probeBitmap(split) else {
                    throw ProbeFailure("split produced no bitmap")
                }
                let a = split.arrangedSubviews[0].frame
                let b = split.arrangedSubviews[1].frame
                let dividerRect = CGRect(x: a.maxX, y: split.bounds.midY - 40,
                                         width: max(1, b.minX - a.maxX), height: 80)
                guard let rendered = probeDominantColor(bmp, region: dividerRect) else {
                    throw ProbeFailure("no divider samples at \(dividerRect)")
                }
                let renderedRatio = contrastRatio(rendered, themeBg)
                print("UIPROBE-DIVIDER model_ratio=\(String(format: "%.2f", modelRatio)) rendered_ratio=\(String(format: "%.2f", renderedRatio)) floor=\(ChromeContrast.minimumDividerContrast)")
                guard modelRatio >= ChromeContrast.minimumDividerContrast - 0.01 else {
                    throw ProbeFailure("divider color contrast \(modelRatio) below the L2 floor")
                }
                // Rendered floor is looser (AA + sampling), same idea as the
                // chip gate's 1.6-vs-3.0 split.
                guard renderedRatio >= 1.3 else {
                    probeScreenshot(split, name: "divider-contrast-fail")
                    throw ProbeFailure("rendered divider contrast \(renderedRatio) — invisible on this theme")
                }
                // Restore the world for the legs after us.
                if let pane = dividerPane { controller.close(pane: pane) }
                // The unwrap must hand the survivor back to frame layout
                // (the replace() translates fix this leg caught).
                guard controller.allPanes().allSatisfy({
                    $0.superview is NSSplitView
                        || $0.translatesAutoresizingMaskIntoConstraints
                }) else {
                    throw ProbeFailure("unwrapped pane left constraint-driven — the 378x0 collapse class")
                }
            }))

        // #10: chips sit one visual level below the tab pills (smaller type,
        // smaller pill), and the gear/+ trailing cluster is aligned.
        probe.add(ProbeStep(
            name: "chip-pill-hierarchy",
            assert: { [self] in
                guard let host = keyHost(), let strip = host.tabStrip,
                      let selectedId = host.selectedTab?.tabId else {
                    throw ProbeFailure("no strip (hierarchy leg)")
                }
                guard config.workspaceBar else {
                    probe.skipLine(step: "chip-pill-hierarchy",
                                   reason: "workspace_bar=false")
                    return
                }
                guard let bar = host.workspaceBar,
                      let chip = bar.probeChipView(activeWorkspaceId),
                      let tabFont = strip.probeLabelFontSize(of: selectedId),
                      let tabFrame = strip.probeItemFrame(of: selectedId) else {
                    throw ProbeFailure("no chip/tab to compare")
                }
                let chipFont = chip.probeLabelFontSize
                let smaller = chipFont < tabFont && chip.frame.height < tabFrame.height
                var aligned = true
                var gearMid = CGFloat(-1), plusMid = CGFloat(-1)
                if let gear = host.gearFrameInWindow(),
                   let plus = strip.probePlusFrameInWindow() {
                    gearMid = gear.midX
                    plusMid = plus.midX
                    aligned = abs(gearMid - plusMid) <= 0.5
                }
                print("UIPROBE-HIERARCHY chip_font=\(chipFont) tab_font=\(tabFont) chip_h=\(chip.frame.height) tab_h=\(tabFrame.height) gear_mid=\(gearMid) plus_mid=\(plusMid) aligned=\(aligned)")
                guard smaller else {
                    throw ProbeFailure("chips do not read below the tab pills (chip \(chipFont)pt/\(chip.frame.height)pt vs tab \(tabFont)pt/\(tabFrame.height)pt)")
                }
                guard aligned else {
                    throw ProbeFailure("gear/+ cluster misaligned: gear midX \(gearMid) vs plus midX \(plusMid)")
                }
            }))

        // Founder bug (2026-09-09): "the settings in appearance sets the size
        // of the text but the tabs/workspace does not really abide by this
        // setting". Flip Appearance › Size LIVE (the Settings path,
        // applyConfigLive) and assert the RENDERED chrome follows
        // ChromeMetrics: pill + chip fonts, both row heights — and the
        // council-#10 hierarchy survives the scale. Restores the config after.
        probe.add(ProbeStep(
            name: "chrome-scales-with-size",
            assert: { [self] in
                guard let host = keyHost(), let strip = host.tabStrip,
                      let selectedId = host.selectedTab?.tabId else {
                    throw ProbeFailure("no strip (chrome-scale leg)")
                }
                let original = config
                let bigSize = original.fontSize + 7   // 13 → 20: pill 11 → 17
                var big = original
                big.fontSize = bigSize
                let expected = ChromeMetrics.derived(fromTerminalFontSize: bigSize)
                let before = strip.probeLabelFontSize(of: selectedId) ?? -1
                defer {
                    applyConfigLive(original)
                    host.window?.contentView?.layoutSubtreeIfNeeded()
                }
                applyConfigLive(big)
                host.window?.contentView?.layoutSubtreeIfNeeded()
                guard let tabFont = strip.probeLabelFontSize(of: selectedId),
                      let tabFrame = strip.probeItemFrame(of: selectedId) else {
                    throw ProbeFailure("no tab to measure after resize")
                }
                let stripH = strip.frame.height
                var chipFont = CGFloat(-1), chipH = CGFloat(-1), barH = CGFloat(-1)
                if config.workspaceBar, let bar = host.workspaceBar,
                   let chip = bar.probeChipView(activeWorkspaceId) {
                    chipFont = chip.probeLabelFontSize
                    chipH = chip.frame.height
                    barH = bar.frame.height
                }
                print("UIPROBE-CHROME-SCALE size=\(bigSize) tab_font=\(before)->\(tabFont) strip_h=\(stripH) chip_font=\(chipFont) chip_h=\(chipH) bar_h=\(barH) expected_pill=\(expected.pillFontSize) expected_strip=\(expected.tabStripHeight)")
                guard tabFont == CGFloat(expected.pillFontSize), tabFont > before else {
                    throw ProbeFailure("tab pill font \(tabFont)pt did not follow Appearance › Size (expected \(expected.pillFontSize)pt, was \(before)pt)")
                }
                guard abs(stripH - CGFloat(expected.tabStripHeight)) <= 0.5 else {
                    throw ProbeFailure("tab strip height \(stripH) did not follow size (expected \(expected.tabStripHeight))")
                }
                if config.workspaceBar {
                    guard chipFont == CGFloat(expected.chipFontSize) else {
                        throw ProbeFailure("chip font \(chipFont)pt did not follow size (expected \(expected.chipFontSize)pt)")
                    }
                    guard abs(barH - CGFloat(expected.workspaceBarHeight)) <= 0.5 else {
                        throw ProbeFailure("workspace bar height \(barH) did not follow size (expected \(expected.workspaceBarHeight))")
                    }
                    guard chipFont < tabFont, chipH < tabFrame.height else {
                        throw ProbeFailure("council #10 hierarchy broke at size \(bigSize): chip \(chipFont)pt/\(chipH) vs tab \(tabFont)pt/\(tabFrame.height)")
                    }
                }
            }))
    }

    // -----------------------------------------------------------------
    // Council #1: the workspace dialogs are window SHEETS with a live,
    // focused, select-all'd name field — Esc cancels, Enter commits —
    // and the destructive choice is styled and titled honestly.
    // -----------------------------------------------------------------
    private func addWorkspaceSheetSteps(_ probe: ProbeRunner) {
        var wsCountBefore = 0
        var activeBefore = ""
        var createdId: String?
        var deleteScratchId: String?

        // New Workspace opens as a sheet on the key window; the name field
        // is focused with its text selected THE MOMENT the sheet opens (the
        // founder's pet-peeve: runModal's dead unfocused field).
        probe.addStateful(ProbeStep(
            name: "workspace-sheet-field-focus",
            action: { [self] in
                wsCountBefore = memory?.store.listWorkspaces().count ?? 0
                activeBefore = activeWorkspaceId
                newWorkspaceAction(nil)
            },
            condition: { [self] in keyHost()?.window?.attachedSheet != nil },
            assert: { [self] in
                guard let sheet = keyHost()?.window?.attachedSheet,
                      let sheetRoot = sheet.contentView,
                      let field = probeFindField(sheetRoot) else {
                    throw ProbeFailure("New Workspace did not open as a sheet with a field")
                }
                guard probeFindButton(sheetRoot, title: "Create") != nil else {
                    throw ProbeFailure("commit button is not the verb 'Create'")
                }
                let editor = sheet.firstResponder as? NSTextView
                let focused = editor != nil && editor === field.currentEditor()
                let selectedAll = editor?.selectedRange == NSRange(
                    location: 0, length: (field.stringValue as NSString).length)
                print("UIPROBE-WSSHEET opened=true focused=\(focused) selected_all=\(selectedAll) initial=\(field.stringValue)")
                guard focused else {
                    throw ProbeFailure("name field not focused on open (firstResponder=\(String(describing: sheet.firstResponder)))")
                }
                guard selectedAll else {
                    throw ProbeFailure("name field text not select-all'd on open")
                }
            }))

        // Esc cancels: one real key event through the sheet's own dispatch.
        probe.addStateful(ProbeStep(
            name: "workspace-sheet-esc-cancels",
            action: { [self] in
                guard let sheet = keyHost()?.window?.attachedSheet else { return }
                probeSendKey(sheet, keyCode: 53, characters: "\u{1b}")
            },
            condition: { [self] in keyHost()?.window?.attachedSheet == nil },
            assert: { [self] in
                let count = memory?.store.listWorkspaces().count ?? -1
                print("UIPROBE-WSSHEET esc_cancelled=true workspaces=\(count) before=\(wsCountBefore)")
                guard count == wsCountBefore else {
                    throw ProbeFailure("Esc-cancelled sheet still changed the workspace list")
                }
            }))

        // Enter commits: reopen, type a name, press Return — the workspace
        // exists and is switched to (the New Workspace contract).
        probe.addStateful(ProbeStep(
            name: "workspace-sheet-enter-commits",
            action: { [self] in newWorkspaceAction(nil) },
            condition: { [self] in keyHost()?.window?.attachedSheet != nil },
            assert: { [self] in
                guard let sheet = keyHost()?.window?.attachedSheet,
                      let sheetRoot = sheet.contentView,
                      let field = probeFindField(sheetRoot) else {
                    throw ProbeFailure("reopened New Workspace sheet lacks its field")
                }
                field.stringValue = "Probe-Sheet-WS"
                guard probePressReturn(in: sheet, expectedTitle: "Create") else {
                    throw ProbeFailure("Enter is not mapped to the sheet's Create button")
                }
            }))
        probe.addStateful(ProbeStep(
            name: "workspace-sheet-committed",
            condition: { [self] in
                guard keyHost()?.window?.attachedSheet == nil,
                      let store = memory?.store else { return false }
                return store.listWorkspaces().contains { $0.name == "Probe-Sheet-WS" }
            },
            assert: { [self] in
                guard let store = memory?.store,
                      let created = store.listWorkspaces().first(where: { $0.name == "Probe-Sheet-WS" }) else {
                    throw ProbeFailure("Enter did not create the workspace")
                }
                createdId = created.id
                let switched = activeWorkspaceId == created.id
                print("UIPROBE-WSSHEET enter_committed=true switched=\(switched)")
                guard switched else {
                    throw ProbeFailure("New Workspace commit did not switch to the new workspace")
                }
                // World restored: back to the pre-leg workspace, fixture
                // forgotten through the FR-50/57 path.
                switchToWorkspace(activeBefore)
                if let createdId { forgetWorkspace(createdId) }
            },
            onFailure: { [self] in
                print("UIPROBE-WSSHEET enter_committed=false names=\(memory?.store.listWorkspaces().map(\.name) ?? [])")
            }))

        // Delete Workspace: a sheet whose title asks the actual question
        // (park vs forget), with destructive styling on Forget; Esc leaves
        // the workspace untouched.
        probe.addStateful(ProbeStep(
            name: "workspace-delete-sheet",
            action: { [self] in
                deleteScratchId = createWorkspace(named: "DeleteProbe")
                if let deleteScratchId { confirmDeleteWorkspace(deleteScratchId) }
            },
            condition: { [self] in keyHost()?.window?.attachedSheet != nil },
            assert: { [self] in
                guard let sheet = keyHost()?.window?.attachedSheet,
                      let sheetRoot = sheet.contentView else {
                    throw ProbeFailure("Delete Workspace did not open as a sheet")
                }
                guard let forget = probeFindButton(sheetRoot, title: "Forget"),
                      probeFindButton(sheetRoot, title: "Park") != nil,
                      probeFindButton(sheetRoot, title: "Cancel") != nil else {
                    throw ProbeFailure("delete sheet lacks Park/Forget/Cancel")
                }
                let honest = probeFindTextInViews(sheetRoot, containing: "Park or forget")
                print("UIPROBE-WSDELETE sheet=true destructive_forget=\(forget.hasDestructiveAction) honest_title=\(honest)")
                guard forget.hasDestructiveAction else {
                    throw ProbeFailure("Forget lacks destructive styling")
                }
                guard honest else {
                    throw ProbeFailure("delete sheet title does not name the park-vs-forget choice")
                }
                probeSendKey(sheet, keyCode: 53, characters: "\u{1b}")
            }))
        probe.addStateful(ProbeStep(
            name: "workspace-delete-esc-keeps",
            condition: { [self] in keyHost()?.window?.attachedSheet == nil },
            assert: { [self] in
                guard let store = memory?.store, let scratch = deleteScratchId else {
                    throw ProbeFailure("delete-sheet leg lost its fixture")
                }
                let kept = store.listWorkspaces().contains { $0.id == scratch }
                print("UIPROBE-WSDELETE esc_kept=\(kept)")
                guard kept else {
                    throw ProbeFailure("Esc on the delete sheet still removed the workspace")
                }
                forgetWorkspace(scratch)  // world restored
            }))
    }

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

    // MARK: - SCROLL UX legs (selection survives scroll + overlay scrollbar)

    /// Buffer-absolute row (a Position row) whose full trimmed text equals
    /// `exact` — the scroll-invariant walk PaneView.scrollbackText uses.
    /// Exact match keeps the shell's ECHOED command line (prompt + command)
    /// from shadowing the command's OUTPUT line.
    private func probeAbsoluteRow(of exact: String, in pane: PaneView) -> Int? {
        let terminal = pane.getTerminal()
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            if line.translateToString(trimRight: true) == exact {
                return row - terminal.buffer.totalLinesTrimmed
            }
            row += 1
        }
        return nil
    }

    /// PROBE-ONLY frame repair for the geometry-asserting scroll-UX legs.
    /// Quiet-mode quirk, verified pre-existing at HEAD f253ed3 with a frame
    /// tracer: after tab-select gestures, a layout-engine pass in the
    /// never-displayed offscreen window can re-apply STALE zero-size derived
    /// constraints to a presented pane
    /// (NSViewActuallyUpdateFrameFromLayoutEngine ← [NSView layout]); a real
    /// on-screen display pass refreshes them, which quiet runs never get.
    /// Re-adopting the superview bounds is exactly what that display pass
    /// would settle on. Model-level legs never need this.
    private func probeRepairPaneFrame(_ pane: PaneView) {
        if pane.bounds.width < 50 || pane.bounds.height < 50,
           let sv = pane.superview, sv.bounds.width >= 50, sv.bounds.height >= 50 {
            pane.frame = sv.bounds
        }
        pane.scrollerOverlay?.updateFrameToBand()
    }

    /// A real mouse event aimed at a point in `view`'s own coordinates, for
    /// driving the overlay scroller's actual event handlers.
    private func probeMouseEvent(_ type: NSEvent.EventType, in view: NSView,
                                 at point: NSPoint, clickCount: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type,
                           location: view.convert(point, to: nil),
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0,
                           context: nil, eventNumber: 0, clickCount: clickCount,
                           pressure: 1)
    }

    /// Founder asks (SCROLL UX stage): 1) a selection is anchored to buffer
    /// CONTENT — it scrolls with the text, survives streaming output, and a
    /// mid-drag extension stays glued to where the drag started (headless
    /// twin: SelectionScrollAnchoringTests); 2) every pane carries an
    /// auto-hiding overlay scrollbar — appears on scroll activity, knob
    /// proportional and draggable, track clicks page, fades ~1s idle, and
    /// eats no terminal events while hidden. Stateless behaviors — fresh
    /// mode is sufficient (they run in restored too via the shared list,
    /// which is free extra coverage).
    // swiftlint:disable:next function_body_length
    private func addScrollUXSteps(_ probe: ProbeRunner) {
        var pane: PaneView?
        var savedCopyOnSelect = true
        var selectionTextBefore: String?

        probe.add(ProbeStep(
            name: "selection-scroll-setup", timeout: 12,
            action: { [self] in
                // A tab whose pane PRESENTS with real bounds, selected via
                // the real gesture path. (Quiet-mode quirk, PROBE-ONLY — see
                // probeRepairPaneFrame: a tab re-selected by the earlier
                // gesture legs can carry zero-frame layout-engine constants
                // that a display pass would refresh but an offscreen run
                // never does — so these legs pick a healthy tab instead of
                // fighting the engine.)
                guard let host = hosts.first(where: { $0.window?.isVisible == true })
                        ?? keyHost(),
                      let controller = host.tabs.first(where: { c in
                          c.allPanes().contains {
                              !($0 is SerialPaneView) && $0.bounds.width >= 50
                                  && $0.bounds.height >= 50
                          }
                      }),
                      let target = controller.allPanes()
                          .first(where: { !($0 is SerialPaneView) }) else {
                    probeFail("scroll-ux: no presented shell pane")
                }
                host.select(controller)
                pane = target
                // Keep the runner's clipboard out of it: copy-on-select would
                // clobber the pasteboard on every selection this leg makes.
                savedCopyOnSelect = target.copyOnSelect
                target.copyOnSelect = false
                target.send(txt: "printf 'SELMARKA-one\\n'; seq 1 5\r")
            },
            // NOTE: no geometry conditions or frame repairs in the SELECTION
            // legs — they certify model/selection truth, which holds on a
            // zero-framed quiet-mode pane, and a frame repair goes through
            // resizeSubviews, which clears the selection by design.
            condition: { [self] in
                guard let pane else { return false }
                return probeAbsoluteRow(of: "SELMARKA-one", in: pane) != nil
                    && probeAbsoluteRow(of: "5", in: pane) != nil
            },
            onFailure: { [self] in
                for (i, h) in hosts.enumerated() {
                    print("UIPROBE-SCROLLUX host[\(i)] ws=\(h.workspaceId ?? "nil") visible=\(h.window?.isVisible == true) selected=\(h.selectedTab?.tabId.prefix(8) ?? "nil") tabs=\(h.tabs.map { "\($0.tabId.prefix(8)):\($0.allPanes().map { p in "\(Int(p.bounds.width))x\(Int(p.bounds.height))" })" })")
                }
                if let pane {
                    var chain: [String] = []
                    var v: NSView? = pane
                    while let view = v {
                        chain.append("\(type(of: view)):\(Int(view.frame.width))x\(Int(view.frame.height))")
                        v = view.superview
                    }
                    print("UIPROBE-SCROLLUX pane_chain=\(chain.joined(separator: " < "))")
                }
            }))

        // The founder bug itself: with a selection standing, STREAMING output
        // must neither clear it nor move it off its content. (SwiftTerm
        // 1.20.0 cleared it in feedPrepare/linefeed whenever
        // allowMouseReporting was true — the config default — even with no
        // app tracking the mouse; PaneView now derives that flag.)
        probe.add(ProbeStep(
            name: "selection-survives-stream", timeout: 15,
            action: { [self] in
                guard let pane, let row = probeAbsoluteRow(of: "SELMARKA-one", in: pane)
                else { probeFail("selection leg: marker row not found") }
                // The drag path's own service calls (mouseDown/mouseDragged
                // route through exactly these — verified in
                // MacTerminalView.swift).
                let selection = pane.selection!
                selection.setSoftStart(bufferPosition: Position(col: 0, row: row))
                selection.startSelection()
                selection.dragExtend(bufferPosition: Position(col: 12, row: row))
                selectionTextBefore = pane.getSelection()
                guard selectionTextBefore?.contains("SELMARKA-one") == true else {
                    probeFail("selection leg: seeded selection reads \(selectionTextBefore ?? "nil")")
                }
                pane.send(txt: "seq 1 200; echo selstream-done\r")
            },
            condition: { [self] in
                guard let pane else { return false }
                return probeAbsoluteRow(of: "selstream-done", in: pane) != nil
            },
            assert: {
                guard let pane else { throw ProbeFailure("pane lost") }
                let text = pane.getSelection()
                print("UIPROBE-SELECTION active=\(pane.selectionActive) text=\(text?.debugDescription ?? "nil") can_scroll=\(pane.canScroll)")
                guard pane.selectionActive else {
                    throw ProbeFailure("streaming output cleared the selection (the founder bug)")
                }
                guard text == selectionTextBefore else {
                    throw ProbeFailure("selection drifted off its content: \(text?.debugDescription ?? "nil") != \(selectionTextBefore?.debugDescription ?? "nil")")
                }
                guard pane.canScroll else {
                    throw ProbeFailure("stream did not scroll the buffer — leg proved nothing")
                }
            },
            onFailure: {
                print("UIPROBE-SELECTION tail=\(pane?.scrollbackText(maxLines: 60).suffix(300) ?? "")")
            }))

        // Mid-drag: with the button conceptually down, output streams, the
        // anchor stays glued to its content, and the continuing drag extends
        // over the content now under the pointer.
        probe.add(ProbeStep(
            name: "selection-mid-drag-glued", timeout: 15,
            action: { [self] in
                guard let pane, let row = probeAbsoluteRow(of: "selstream-done", in: pane)
                else { probeFail("mid-drag leg: anchor row not found") }
                let selection = pane.selection!
                selection.setSoftStart(bufferPosition: Position(col: 0, row: row))
                selection.startSelection()
                selection.dragExtend(bufferPosition: Position(col: 14, row: row))
                selectionTextBefore = pane.getSelection()
                pane.send(txt: "seq 1 60; echo middrag-done\r")
            },
            condition: { [self] in
                guard let pane else { return false }
                return probeAbsoluteRow(of: "middrag-done", in: pane) != nil
            },
            assert: { [self] in
                guard let pane else { throw ProbeFailure("pane lost") }
                guard pane.selectionActive, pane.getSelection() == selectionTextBefore else {
                    throw ProbeFailure("in-flight drag lost its content anchor (got \(pane.getSelection()?.debugDescription ?? "nil"))")
                }
                guard let target = probeAbsoluteRow(of: "middrag-done", in: pane) else {
                    throw ProbeFailure("mid-drag leg: target row vanished")
                }
                // The drag continues to the CURRENT position of later
                // content — what mouseDragged passes for the pointer now.
                pane.selection.dragExtend(bufferPosition: Position(col: 12, row: target))
                let extended = pane.getSelection() ?? ""
                print("UIPROBE-SELECTION mid_drag_glued=true extended_len=\(extended.count)")
                guard extended.contains("selstream-done"), extended.contains("middrag-done") else {
                    throw ProbeFailure("drag extension not glued to content (got \(extended.debugDescription.prefix(120)))")
                }
                pane.selectNone()
                pane.copyOnSelect = savedCopyOnSelect
            }))

        // The derived-flag contract both ways: an app enabling mouse tracking
        // gets its events (allowMouseReporting flips on), and turning it off
        // restores feed-time selection preservation.
        probe.add(ProbeStep(
            name: "mouse-reporting-flag-syncs", timeout: 10,
            action: { pane?.send(txt: "printf '\\e[?1000h'; echo mr-on\r") },
            condition: { [self] in
                guard let pane else { return false }
                return probeAbsoluteRow(of: "mr-on", in: pane) != nil
            },
            assert: {
                guard let pane else { throw ProbeFailure("pane lost") }
                let mode = pane.getTerminal().mouseMode
                print("UIPROBE-MOUSEREPORT mode_active=\(mode != .off) allow=\(pane.allowMouseReporting)")
                guard mode != .off else { throw ProbeFailure("\\e[?1000h did not enable mouse mode") }
                guard pane.allowMouseReporting else {
                    throw ProbeFailure("allowMouseReporting not restored for a mouse-tracking app")
                }
            }))
        probe.add(ProbeStep(
            name: "mouse-reporting-flag-clears", timeout: 10,
            action: { pane?.send(txt: "printf '\\e[?1000l'; echo mr-off\r") },
            condition: { [self] in
                guard let pane else { return false }
                return probeAbsoluteRow(of: "mr-off", in: pane) != nil
            },
            assert: {
                guard let pane else { throw ProbeFailure("pane lost") }
                guard pane.getTerminal().mouseMode == .off else {
                    throw ProbeFailure("\\e[?1000l did not disable mouse mode")
                }
                guard !pane.allowMouseReporting else {
                    throw ProbeFailure("allowMouseReporting stuck on — feed-time clears would return")
                }
            }))

        // ---- Overlay scrollbar ----
        probe.add(ProbeStep(
            name: "overlay-scroller-appears", timeout: 15,
            action: {
                pane?.send(txt: "seq 1 250\r")
            },
            condition: { [self] in
                guard let pane else { return false }
                probeRepairPaneFrame(pane)
                return pane.canScroll && pane.bounds.height >= 100
                    && probeAbsoluteRow(of: "250", in: pane) != nil
            },
            assert: {
                guard let pane, let overlay = pane.scrollerOverlay else {
                    throw ProbeFailure("no overlay scroller installed on the pane")
                }
                // Scroll to mid-history: activity must present the bar with a
                // plausible, proportional knob.
                pane.scroll(toPosition: 0.5)
                guard overlay.probeVisible else {
                    throw ProbeFailure("overlay scroller did not appear on scroll activity")
                }
                guard let knob = overlay.probeKnobFrame() else {
                    throw ProbeFailure("overlay scroller has no knob while scrollable")
                }
                let track = overlay.bounds.height
                print("UIPROBE-SCROLLER visible=true knob_y=\(Int(knob.minY)) knob_h=\(Int(knob.height)) track_h=\(Int(track)) position=\(String(format: "%.2f", pane.scrollPosition)) thumb=\(String(format: "%.3f", pane.scrollThumbsize))")
                guard knob.height >= OverlayScrollerLayout.minKnobLength,
                      knob.height < track / 2 else {
                    throw ProbeFailure("knob geometry implausible: h=\(knob.height) of track=\(track)")
                }
                guard abs(pane.scrollPosition - 0.5) < 0.1 else {
                    throw ProbeFailure("scroll(toPosition: 0.5) landed at \(pane.scrollPosition)")
                }
                // Rendered-bitmap truth (§2.3): VISIBLE pass only, the same
                // split the composited chrome truths use. In quiet offscreen
                // runs cacheDisplay's internal layout pass re-zeroes the band
                // (the stale-engine quirk above) faster than any repair, so
                // the pixel half of this leg belongs to the run where real
                // display passes keep frames honest. Knob and track are white
                // at different ALPHAS, so the capture is composited over a
                // known dark ground first; an undrawn overlay stays uniform
                // and fails.
                // Rendered-bitmap truth (§2.3): render the band's own
                // drawing (the exact draw() body, parameterized) into an
                // offscreen context of KNOWN geometry and assert real pixels
                // over a dark ground. Deliberately not a cacheDisplay or
                // window capture: cacheDisplay's internal layout pass
                // re-zeroes the band via the stale-engine quirk documented on
                // probeRepairPaneFrame, and CGWindowListCreateImage needs an
                // on-screen composited window — neither exists in quiet runs.
                let renderSize = NSSize(width: OverlayScrollerLayout.bandWidth,
                                        height: 400)
                let composed = NSImage(size: renderSize)
                composed.lockFocus()
                // Ground OPPOSITE the theme's knob color (light themes draw a
                // black-alpha knob — the light-theme matrix leg caught a
                // black-on-black uniform sample here).
                (overlay.probeDarkGround ? NSColor.black : NSColor.white).setFill()
                NSRect(origin: .zero, size: renderSize).fill()
                overlay.renderBand(in: NSRect(origin: .zero, size: renderSize),
                                   metrics: OverlayScrollerMetrics(
                                       trackLength: renderSize.height,
                                       proportion: pane.scrollThumbsize,
                                       position: CGFloat(pane.scrollPosition)))
                composed.unlockFocus()
                guard let tiff = composed.tiffRepresentation,
                      let bmp = NSBitmapImageRep(data: tiff) else {
                    throw ProbeFailure("overlay band render unavailable")
                }
                // Middle third — the knob sits there at position 0.5.
                let middle = CGRect(x: 0, y: renderSize.height / 3,
                                    width: renderSize.width,
                                    height: renderSize.height / 3)
                try assertRendered(bmp, region: middle, what: "overlay scroller knob")
                print("UIPROBE-SCROLLER band_rendered_ok=true")
            },
            onFailure: {
                if let pane, let overlay = pane.scrollerOverlay {
                    print("UIPROBE-SCROLLER hidden=\(overlay.isHidden) alpha=\(overlay.alphaValue) frame=\(overlay.frame) pane_bounds=\(pane.bounds) can_scroll=\(pane.canScroll)")
                }
            }))

        probe.add(ProbeStep(
            name: "overlay-scroller-drag", timeout: 8,
            assert: { [self] in
                if let pane { probeRepairPaneFrame(pane) }
                guard let pane, let overlay = pane.scrollerOverlay,
                      let knob = overlay.probeKnobFrame() else {
                    throw ProbeFailure("drag leg: no knob")
                }
                let grab = NSPoint(x: knob.midX, y: knob.midY)
                guard let down = probeMouseEvent(.leftMouseDown, in: overlay, at: grab) else {
                    throw ProbeFailure("drag leg: could not synthesize events")
                }
                overlay.mouseDown(with: down)
                guard overlay.probeVisible else {
                    throw ProbeFailure("bar not pinned visible during a knob drag")
                }
                // To the very top of the track → oldest scrollback.
                let top = NSPoint(x: knob.midX, y: knob.height / 2)
                overlay.mouseDragged(with: probeMouseEvent(.leftMouseDragged, in: overlay, at: top)!)
                let atTop = pane.scrollPosition
                // And to the very bottom → live edge.
                let bottom = NSPoint(x: knob.midX, y: overlay.bounds.height - knob.height / 2)
                overlay.mouseDragged(with: probeMouseEvent(.leftMouseDragged, in: overlay, at: bottom)!)
                let atBottom = pane.scrollPosition
                overlay.mouseUp(with: probeMouseEvent(.leftMouseUp, in: overlay, at: bottom)!)
                print("UIPROBE-SCROLLER drag_top_position=\(String(format: "%.3f", atTop)) drag_bottom_position=\(String(format: "%.3f", atBottom))")
                guard atTop < 0.01 else {
                    throw ProbeFailure("knob drag to top landed at \(atTop), want 0")
                }
                guard atBottom > 0.99 else {
                    throw ProbeFailure("knob drag to bottom landed at \(atBottom), want 1")
                }
            }))

        // With the bar VISIBLE (pinned by the drag above), the band eats only
        // its own 12pt strip: a click point in the band resolves to the
        // overlay, a point outside it resolves through to the pane — the
        // terminal's mouse path (selection drags, mouse reporting) is never
        // intercepted outside the band.
        probe.add(ProbeStep(
            name: "overlay-scroller-click-transparency", timeout: 8,
            assert: { [self] in
                if let pane { probeRepairPaneFrame(pane) }
                guard let pane, let overlay = pane.scrollerOverlay else {
                    throw ProbeFailure("transparency leg: overlay lost")
                }
                // Fresh activity keeps the leg honest even if the ~1s idle
                // fade elapsed between steps.
                if !overlay.probeVisible { pane.scrollUp(lines: 1) }
                guard overlay.probeVisible else {
                    throw ProbeFailure("transparency leg: band would not present on activity")
                }
                // NSView.hitTest takes superview coordinates.
                func paneHit(atPaneX x: CGFloat, y: CGFloat) -> NSView? {
                    pane.hitTest(pane.convert(NSPoint(x: x, y: y),
                                              to: pane.superview))
                }
                let inBand = paneHit(atPaneX: pane.bounds.width
                                        - OverlayScrollerLayout.bandWidth / 2,
                                     y: pane.bounds.midY)
                let outsideBand = paneHit(atPaneX: pane.bounds.midX,
                                          y: pane.bounds.midY)
                let bandHitOK = inBand === overlay
                    || inBand?.isDescendant(of: overlay) == true
                let outsideRoutesToPane = outsideBand != nil
                    && outsideBand?.isDescendant(of: overlay) != true
                print("UIPROBE-SCROLLER visible_band_hit=\(bandHitOK) outside_band_hits_pane=\(outsideRoutesToPane) outside_view=\(outsideBand.map { String(describing: type(of: $0)) } ?? "nil")")
                guard bandHitOK else {
                    throw ProbeFailure("visible band did not claim clicks in its own strip")
                }
                guard outsideRoutesToPane else {
                    throw ProbeFailure("visible scroller intercepts clicks outside its band (hit=\(String(describing: outsideBand)))")
                }
            }))

        probe.add(ProbeStep(
            name: "overlay-scroller-track-page", timeout: 8,
            assert: { [self] in
                if let pane { probeRepairPaneFrame(pane) }
                guard let pane, let overlay = pane.scrollerOverlay,
                      let knob = overlay.probeKnobFrame() else {
                    throw ProbeFailure("page leg: no knob")
                }
                // Knob sits at the bottom (previous leg): click ABOVE it.
                let before = pane.getTerminal().buffer.yDisp
                let above = NSPoint(x: knob.midX, y: max(knob.minY - 10, 1))
                overlay.mouseDown(with: probeMouseEvent(.leftMouseDown, in: overlay, at: above)!)
                overlay.mouseUp(with: probeMouseEvent(.leftMouseUp, in: overlay, at: above)!)
                let after = pane.getTerminal().buffer.yDisp
                let rows = pane.getTerminal().rows
                print("UIPROBE-SCROLLER page_up_ydisp \(before)->\(after) rows=\(rows)")
                guard after == max(before - rows, 0), after < before else {
                    throw ProbeFailure("track click above the knob did not page up (\(before)->\(after))")
                }
            }))

        probe.add(ProbeStep(
            name: "overlay-scroller-fades", timeout: 10,
            action: {
                // Back to the live bottom for the legs that follow; that is
                // itself scroll activity — the fade condition then waits out
                // the ~1s idle delay.
                pane?.scroll(toPosition: 1.0)
            },
            condition: {
                // Wait for the VIEW to fade, not just the visibility model:
                // the model expires a beat before the scheduled fade work
                // runs, and a poll landing in that window met the old
                // condition while hitTest (keyed on isHidden/alpha) still
                // returned the band — a phase-of-poll flake, caught live
                // 2026-09-02 when new legs shifted the poll cadence.
                guard let overlay = pane?.scrollerOverlay else { return false }
                return !overlay.probeVisible
                    && (overlay.isHidden || overlay.alphaValue <= 0.1)
            },
            assert: {
                guard let pane, let overlay = pane.scrollerOverlay else {
                    throw ProbeFailure("fade leg: overlay lost")
                }
                // Hidden bar must not eat terminal mouse events: hit-testing
                // its band resolves to nothing.
                let bandPoint = NSPoint(x: overlay.frame.midX, y: overlay.frame.midY)
                guard overlay.hitTest(bandPoint) == nil else {
                    throw ProbeFailure("hidden scroller still intercepts mouse events in its band")
                }
                print("UIPROBE-SCROLLER faded=true hit_test_transparent=true")
            },
            onFailure: {
                if let overlay = pane?.scrollerOverlay {
                    print("UIPROBE-SCROLLER hidden=\(overlay.isHidden) alpha=\(overlay.alphaValue)")
                }
            }))

        // Per-pane in a split: each pane owns its own band — scrolling one
        // pane presents ITS band only, the sibling's stays hidden. The split
        // is torn down through the real close(pane:) path afterwards.
        var splitPane: PaneView?
        var splitController: TerminalWindowController?
        var splitPaneCountBefore = 0
        probe.add(ProbeStep(
            name: "overlay-scroller-per-pane-split", timeout: 20,
            action: { [self] in
                guard let pane,
                      let controller = controllers.first(where: { c in
                          c.allPanes().contains { $0 === pane }
                      }) else {
                    probeFail("per-pane leg: scroll-ux pane lost its controller")
                }
                splitController = controller
                if let host = controller.host {
                    host.focusWindow()
                    host.select(controller)
                }
                let before = controller.allPanes()
                splitPaneCountBefore = before.count
                controller.splitCurrentPane(vertical: false)
                splitPane = controller.allPanes()
                    .first { p in !before.contains { $0 === p } }
                guard let fresh = splitPane else {
                    probeFail("per-pane leg: split created no new pane")
                }
                fresh.send(txt: "seq 1 250\r")
            },
            condition: { [self] in
                guard let fresh = splitPane else { return false }
                probeRepairPaneFrame(fresh)
                return fresh.process?.running == true && fresh.canScroll
                    && probeAbsoluteRow(of: "250", in: fresh) != nil
            },
            assert: { [self] in
                guard let pane, let fresh = splitPane,
                      let controller = splitController else {
                    throw ProbeFailure("per-pane leg: setup lost")
                }
                probeRepairPaneFrame(fresh)
                guard let freshOverlay = fresh.scrollerOverlay,
                      let mainOverlay = pane.scrollerOverlay else {
                    throw ProbeFailure("a split pane is missing its overlay scroller")
                }
                guard freshOverlay !== mainOverlay,
                      freshOverlay.superview === fresh,
                      mainOverlay.superview === pane else {
                    throw ProbeFailure("split panes share/misparent overlay scrollers")
                }
                fresh.scroll(toPosition: 0.5)
                let freshVisible = freshOverlay.probeVisible
                let siblingStayedHidden = !mainOverlay.probeVisible
                print("UIPROBE-SCROLLER split_distinct_bands=true fresh_band_visible=\(freshVisible) sibling_band_hidden=\(siblingStayedHidden)")
                guard freshVisible else {
                    throw ProbeFailure("scrolling a split pane did not present its own band")
                }
                guard siblingStayedHidden else {
                    throw ProbeFailure("scrolling one split pane presented the sibling's band too")
                }
                controller.close(pane: fresh)
                guard controller.allPanes().count == splitPaneCountBefore else {
                    throw ProbeFailure("per-pane leg teardown left \(controller.allPanes().count) panes (want \(splitPaneCountBefore))")
                }
            },
            onFailure: {
                print("UIPROBE-SCROLLER split_pane=\(String(describing: splitPane?.bounds)) can_scroll=\(splitPane?.canScroll == true) overlay=\(String(describing: splitPane?.scrollerOverlay?.frame))")
            }))
    }

    // MARK: - Serial legs (pty pair — real /dev/cu.* NEVER touched; keep-list)

    private func addSerialSteps(_ probe: ProbeRunner) {
        var serialMasterFD: Int32 = -1
        var serialPane: SerialPaneView?
        var serialSlavePath = ""
        var serialController: TerminalWindowController?
        // Serial submenu item titles via the REAL context-menu construction
        // (the Disconnect/Connect toggle title must flip with state).
        func serialSubmenuTitles() -> [String] {
            guard let pane = serialPane, let controller = serialController,
                  let submenu = controller.contextMenu(for: pane).items
                      .first(where: { $0.title == "Serial" })?.submenu else { return [] }
            return submenu.items.map(\.title)
        }
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
                serialSlavePath = slavePath
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
                serialController = controller
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
        // SCROLL UX: serial panes carry the same overlay scroll band, with
        // its track stopped above the footer strip. Loopback RX fills the
        // scrollback; a programmatic scroll must present the bar.
        var serialBurst: [UInt8] = []
        probe.add(ProbeStep(
            name: "serial-scroller-band", timeout: 12,
            action: {
                var burst = ""
                for i in 1...150 { burst += "srl-\(i)\r\n" }
                serialBurst = Array(burst.utf8)
            },
            condition: { [self] in
                // The master fd is NONBLOCKING and the pty buffer is small:
                // the ~1.3KB burst goes out in short writes retried across
                // polls as the pane's reader drains the slave side.
                if !serialBurst.isEmpty {
                    let n = serialBurst.withUnsafeBytes {
                        write(serialMasterFD, $0.baseAddress, $0.count)
                    }
                    if n > 0 { serialBurst.removeFirst(n) }
                }
                guard let pane = serialPane else { return false }
                probeRepairPaneFrame(pane)
                return serialBurst.isEmpty && pane.canScroll
                    && pane.scrollbackText(maxLines: 300).contains("srl-150")
            },
            assert: { [self] in
                guard let pane = serialPane, let overlay = pane.scrollerOverlay else {
                    throw ProbeFailure("serial pane has no overlay scroller")
                }
                probeRepairPaneFrame(pane)
                let expectedHeight = pane.bounds.height - SerialFooterView.barHeight
                guard abs(overlay.frame.height - expectedHeight) <= 1 else {
                    throw ProbeFailure("scroll band overlaps the serial footer (band_h=\(overlay.frame.height) pane_h=\(pane.bounds.height))")
                }
                pane.scrollUp(lines: 5)
                guard overlay.probeVisible, let knob = overlay.probeKnobFrame() else {
                    throw ProbeFailure("serial overlay scroller did not appear on scroll")
                }
                print("UIPROBE-SCROLLER serial_band=true band_h=\(Int(overlay.frame.height)) knob_h=\(Int(knob.height))")
                // Back to the live edge so later serial legs read fresh RX.
                pane.scroll(toPosition: 1.0)
            },
            onFailure: {
                if let pane = serialPane {
                    print("UIPROBE-SCROLLER serial can_scroll=\(pane.canScroll) overlay=\(String(describing: pane.scrollerOverlay?.frame))")
                }
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
        // Footer bar (founder ask): strip pinned to the serial pane's bottom;
        // TX/RX lifetime counters advanced by the loopback bytes above and
        // painted through the ≤4 Hz throttle (the condition rides the
        // trailing flush, not a clock).
        probe.add(ProbeStep(
            name: "serial-footer-counters", timeout: 10,
            condition: {
                guard let pane = serialPane, let footer = pane.footerView else { return false }
                return pane.footerModel.rxBytes > 0 && pane.footerModel.txBytes > 0
                    && footer.probeRxText != "RX 0 B" && footer.probeTxText != "TX 0 B"
            },
            assert: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    throw ProbeFailure("serial pane lost (footer leg)")
                }
                // Pinned to the bottom edge, full width, 22 pt (find-bar family).
                pane.layoutSubtreeIfNeeded()
                let frame = footer.frame
                guard footer.superview === pane,
                      frame.height == SerialFooterView.barHeight,
                      frame.minY <= 1, frame.width >= pane.bounds.width - 1 else {
                    throw ProbeFailure("footer not pinned to the pane bottom (frame=\(frame) pane=\(pane.bounds))")
                }
                // Painted truth: the labels carry the model's formatted totals.
                let model = pane.footerModel
                guard footer.probeTxText == "TX \(SerialFooterModel.formatBytes(model.txBytes))",
                      footer.probeRxText == "RX \(SerialFooterModel.formatBytes(model.rxBytes))" else {
                    throw ProbeFailure("footer counters disagree with the model (\(footer.probeTxText) / \(footer.probeRxText) vs tx=\(model.txBytes) rx=\(model.rxBytes))")
                }
                guard footer.currentLinkState == .connected else {
                    throw ProbeFailure("footer state dot not connected-green while connected")
                }
                // HEX badge rides the hex lens (toggled on in serial-tx-crlf).
                guard footer.probeHexBadgeVisible == pane.hexMode else {
                    throw ProbeFailure("HEX badge=\(footer.probeHexBadgeVisible) disagrees with hex lens=\(pane.hexMode)")
                }
                // Rendered-bitmap truth for the strip itself (§2.3 discipline).
                if let bmp = probeBitmap(pane) {
                    try assertRendered(bmp, region: footer.convert(footer.bounds, to: pane),
                                       what: "serial footer strip")
                }
                print("UIPROBE-SERIAL footer_present=true tx=\(footer.probeTxText) rx=\(footer.probeRxText) hex_badge=\(footer.probeHexBadgeVisible)")
            },
            onFailure: {
                print("UIPROBE-SERIAL footer_present=\(serialPane?.footerView != nil) model_tx=\(serialPane?.footerModel.txBytes ?? -1) model_rx=\(serialPane?.footerModel.rxBytes ?? -1) tx_label=\(serialPane?.footerView?.probeTxText ?? "-") rx_label=\(serialPane?.footerView?.probeRxText ?? "-")")
            }))
        // Baud change from the footer control applies termios on the LIVE fd
        // (the port never closes) — asserted by kernel readback through the
        // currentTermios test seam, then round-tripped home so the journal
        // leg's 115200-8N1 fixture settings stand.
        probe.add(ProbeStep(
            name: "serial-footer-baud-live", timeout: 8,
            action: {
                // Same NSMenuItem + action a human selection drives; only the
                // modal popUp is skipped (a probe cannot dismiss a tracking menu).
                serialPane?.footerView?.probeSelectBaud(9600)
            },
            condition: {
                guard let pane = serialPane, var t = pane.currentTermiosForProbe()
                else { return false }
                return cfgetispeed(&t) == 9600 && cfgetospeed(&t) == 9600
            },
            assert: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    throw ProbeFailure("serial pane lost (baud leg)")
                }
                guard pane.isConnected else {
                    throw ProbeFailure("baud change closed the port — must apply live")
                }
                guard pane.setup.settings.baud == 9600,
                      footer.probeBaudTitle == "9600",
                      pane.paneTitle.contains("@ 9600") else {
                    throw ProbeFailure("baud did not propagate (settings=\(pane.setup.settings.compactString) footer=\(footer.probeBaudTitle) title=\(pane.paneTitle))")
                }
                print("UIPROBE-SERIAL baud_live_applied=true termios_ispeed=9600 footer_baud=\(footer.probeBaudTitle) still_connected=true")
                // Round-trip home (also proves a second live apply).
                footer.probeSelectBaud(115200)
                guard var t = pane.currentTermiosForProbe(),
                      cfgetispeed(&t) == 115200, pane.setup.settings.baud == 115200 else {
                    throw ProbeFailure("return to 115200 did not land on the fd")
                }
            },
            onFailure: {
                var speed: speed_t = 0
                if var t = serialPane?.currentTermiosForProbe() { speed = cfgetispeed(&t) }
                print("UIPROBE-SERIAL baud_live_applied=false termios_ispeed=\(speed) settings=\(serialPane?.setup.settings.compactString ?? "-") connected=\(serialPane?.isConnected == true)")
            }))
        // The other half of "applies live": the SAME fd keeps streaming
        // after the termios round-trip — RX written after the baud changes
        // must land in the pane through the original read pump. The pane is
        // in the HEX lens here (serial-tx-crlf switched it on), so the
        // marker is a 4-byte run written 4x — like the deadbeef pattern, at
        // least one run renders intact across any hex line wrap.
        probe.add(ProbeStep(
            name: "serial-baud-stream-after", timeout: 8,
            action: {
                let bytes: [UInt8] = [0xfa, 0xce, 0xb0, 0x0c, 0xfa, 0xce, 0xb0, 0x0c,
                                      0xfa, 0xce, 0xb0, 0x0c, 0xfa, 0xce, 0xb0, 0x0c]
                _ = bytes.withUnsafeBytes { write(serialMasterFD, $0.baseAddress, $0.count) }
            },
            condition: {
                serialPane?.scrollbackText(maxLines: 300).contains("fa ce b0 0c") == true
            },
            assert: {
                guard serialPane?.isConnected == true else {
                    throw ProbeFailure("pane not connected after the live baud round-trip")
                }
                print("UIPROBE-SERIAL post_baud_rx_streams=true")
            },
            onFailure: {
                print("UIPROBE-SERIAL post_baud_rx_streams=false connected=\(serialPane?.isConnected == true) tail=\(serialPane?.scrollbackText(maxLines: 100).suffix(200) ?? "")")
            }))
        // DTR/RTS chips: filled = asserted, click toggles — driven through
        // the REAL chip button action (gesture fidelity). Ptys ENOTTY every
        // modem-line ioctl, so the pane's stub seam stands in for the fd;
        // the gesture path footer → pane → line state is what's under test.
        probe.add(ProbeStep(
            name: "serial-footer-dtr-chip", timeout: 8,
            action: {
                guard let pane = serialPane else { probeFail("serial pane lost (dtr leg)") }
                pane.probeModemLinesStub = SerialModemLines(dtr: false, rts: true,
                                                            cts: false, carrierDetect: false)
                pane.refreshFooter()
                pane.footerView?.dtrChip.performClick(nil)
            },
            condition: {
                serialPane?.probeModemLinesStub?.dtr == true
                    && serialPane?.footerView?.dtrChip.isFilled == true
            },
            assert: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    throw ProbeFailure("serial pane lost (dtr leg)")
                }
                // RTS chip mirrors its line too (stubbed asserted).
                guard footer.rtsChip.isFilled else {
                    throw ProbeFailure("RTS chip not filled while the line is asserted")
                }
                // Second toggle through the same gesture: chip empties.
                footer.dtrChip.performClick(nil)
                guard pane.probeModemLinesStub?.dtr == false, !footer.dtrChip.isFilled else {
                    throw ProbeFailure("DTR chip did not reflect the toggle back off")
                }
                // The footer never steals first responder from the terminal.
                if let fr = pane.window?.firstResponder as? NSView,
                   fr.isDescendant(of: footer) {
                    throw ProbeFailure("footer control took first responder: \(fr)")
                }
                pane.probeModemLinesStub = nil
                pane.refreshFooter()
                print("UIPROBE-SERIAL dtr_chip_reflects=true rts_chip_filled_when_asserted=true footer_never_steals_focus=true")
            },
            onFailure: {
                print("UIPROBE-SERIAL dtr_chip_reflects=false stub_dtr=\(serialPane?.probeModemLinesStub?.dtr == true) chip_filled=\(serialPane?.footerView?.dtrChip.isFilled == true)")
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
                // Footer dot: unplug arms auto-reconnect — orange, driven by
                // the same liveness/hotplug machinery as the banner.
                guard serialPane?.footerView?.currentLinkState == .reconnecting else {
                    throw ProbeFailure("footer dot not reconnecting-orange after unplug (state=\(String(describing: serialPane?.footerView?.currentLinkState)))")
                }
                print("UIPROBE-SERIAL disconnect_banner=true still_connected=false footer_state=reconnecting")
                // Composited footer evidence (visible pass only): the orange
                // reconnecting dot as the founder sees it.
                probeCompositedShot(serialPane?.window, name: "serial-footer-reconnecting")
            },
            onFailure: {
                let text = serialPane?.scrollbackText(maxLines: 200) ?? ""
                print("UIPROBE-SERIAL disconnect_banner=false still_connected=\(serialPane?.isConnected == true) tail=\(text.suffix(200))")
            }))
        // Reconnect keeps the lifetime counters: the model lives on the PANE,
        // and every reconnect path (hotplug return, ⌘R) funnels through
        // connect() — driven here for real against a second pty standing in
        // for the returned device (the revoked slave path cannot come back;
        // probeRebindPath mirrors hotplugAttached's own /dev-renumber
        // rebinding). RX after the reconnect must ACCUMULATE on the old
        // totals, not restart them.
        var reconnectTxBefore = -1
        var reconnectRxBefore = -1
        probe.add(ProbeStep(
            name: "serial-reconnect-keeps-counters", timeout: 10,
            action: {
                guard let pane = serialPane else { probeFail("reconnect leg: pane lost") }
                reconnectTxBefore = pane.footerModel.txBytes
                reconnectRxBefore = pane.footerModel.rxBytes
                guard reconnectTxBefore > 0, reconnectRxBefore > 0 else {
                    probeFail("reconnect leg: counters not primed (tx=\(reconnectTxBefore) rx=\(reconnectRxBefore))")
                }
                let master = posix_openpt(O_RDWR | O_NOCTTY)
                guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
                      let slaveC = ptsname(master),
                      case let slavePath = String(cString: slaveC), !slavePath.isEmpty else {
                    probeFail("reconnect leg: second pty pair")
                }
                var t = termios()
                tcgetattr(master, &t)
                cfmakeraw(&t)
                tcsetattr(master, TCSANOW, &t)
                _ = fcntl(master, F_SETFL, O_NONBLOCK)
                serialMasterFD = master
                serialSlavePath = slavePath
                pane.probeRebindPath(slavePath)
                do { try pane.connect() } catch {
                    probeFail("reconnect leg: connect() failed (\(error))")
                }
                // Hex lens is still on: a 4-byte run written 4x, as above.
                let bytes: [UInt8] = [0xca, 0xfe, 0xf0, 0x0d, 0xca, 0xfe, 0xf0, 0x0d,
                                      0xca, 0xfe, 0xf0, 0x0d, 0xca, 0xfe, 0xf0, 0x0d]
                _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
            },
            condition: {
                guard let pane = serialPane else { return false }
                return pane.footerModel.rxBytes > reconnectRxBefore
                    && pane.scrollbackText(maxLines: 300).contains("ca fe f0 0d")
            },
            assert: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    throw ProbeFailure("reconnect leg: pane/footer lost")
                }
                guard pane.isConnected, footer.currentLinkState == .connected else {
                    throw ProbeFailure("reconnect did not land connected-green (connected=\(pane.isConnected))")
                }
                // ACCUMULATED, not reset: TX untouched by the reconnect, RX
                // strictly above its pre-unplug total.
                guard pane.footerModel.txBytes == reconnectTxBefore else {
                    throw ProbeFailure("reconnect changed the TX total (\(reconnectTxBefore) -> \(pane.footerModel.txBytes))")
                }
                guard pane.footerModel.rxBytes >= reconnectRxBefore + 16 else {
                    throw ProbeFailure("reconnect reset the RX total (\(reconnectRxBefore) -> \(pane.footerModel.rxBytes))")
                }
                print("UIPROBE-SERIAL reconnect_keeps_counters=true tx=\(pane.footerModel.txBytes) rx_before=\(reconnectRxBefore) rx_after=\(pane.footerModel.rxBytes)")
            },
            onFailure: {
                print("UIPROBE-SERIAL reconnect_keeps_counters=false connected=\(serialPane?.isConnected == true) tx=\(serialPane?.footerModel.txBytes ?? -1) rx=\(serialPane?.footerModel.rxBytes ?? -1) before_tx=\(reconnectTxBefore) before_rx=\(reconnectRxBefore)")
            }))
        // ------------------------------------------------------------------
        // Disconnect/connect stage (founder: "opened it at the wrong baud but
        // no way to close it and reopen with the right baud" — and RELEASE
        // the port so esptool/avrdude can flash, then reconnect, keeping
        // pane + scrollback + counters).
        //
        // USER disconnect through the REAL footer dot button action. The
        // money assertion: after the release the PROBE ITSELF open(2)s the
        // pty path — success means the port is genuinely free for a flasher.
        var disconnectTxBefore = -1
        var disconnectRxBefore = -1
        probe.add(ProbeStep(
            name: "serial-user-disconnect-releases-port", timeout: 8,
            action: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    probeFail("disconnect leg: pane/footer lost")
                }
                disconnectTxBefore = pane.footerModel.txBytes
                disconnectRxBefore = pane.footerModel.rxBytes
                guard pane.isConnected else { probeFail("disconnect leg: not connected") }
                footer.dotButton.performClick(nil)  // the dot IS the toggle
            },
            condition: {
                guard let pane = serialPane else { return false }
                return !pane.isConnected
                    && pane.footerView?.currentLinkState == .userDisconnected
                    && pane.scrollbackText(maxLines: 200).contains("memterm: port released")
            },
            assert: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    throw ProbeFailure("disconnect leg: pane/footer lost")
                }
                // MONEY: the fd is really closed — the probe can open the
                // node itself (what esptool/avrdude will do).
                let freeFD = Darwin.open(serialSlavePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
                guard freeFD >= 0 else {
                    throw ProbeFailure("user disconnect did not release \(serialSlavePath) (errno=\(errno))")
                }
                _ = Darwin.close(freeFD)
                // No fd on the pane either (the termios seam answers nil).
                guard pane.currentTermiosForProbe() == nil else {
                    throw ProbeFailure("pane still holds a live fd after user disconnect")
                }
                // Dot flipped to the hollow connect affordance; tooltip
                // states the ACTION, distinct from the orange reconnect arm.
                guard footer.probeDotTitle == "○",
                      footer.probeDotTooltip == "Disconnected — click to connect" else {
                    throw ProbeFailure("footer dot did not flip to ○/connect (title=\(footer.probeDotTitle) tip=\(footer.probeDotTooltip))")
                }
                // Disconnect ≠ close: counters and scrollback stay.
                guard pane.footerModel.txBytes == disconnectTxBefore,
                      pane.footerModel.rxBytes == disconnectRxBefore else {
                    throw ProbeFailure("user disconnect touched the lifetime counters (tx \(disconnectTxBefore)->\(pane.footerModel.txBytes) rx \(disconnectRxBefore)->\(pane.footerModel.rxBytes))")
                }
                guard pane.scrollbackText(maxLines: 300).contains("ca fe f0 0d") else {
                    throw ProbeFailure("user disconnect lost the scrollback")
                }
                // Context-menu toggle title flipped with state.
                let titles = serialSubmenuTitles()
                guard titles.contains("Connect"), !titles.contains("Disconnect") else {
                    throw ProbeFailure("Serial submenu did not flip to Connect (items=\(titles))")
                }
                print("UIPROBE-SERIAL user_disconnect_released=true probe_reopened_path=true dot=\(footer.probeDotTitle) menu_connect=true")
                // Composited footer evidence: the hollow ○ deliberate-release
                // state, distinct from the orange reconnecting arm.
                probeCompositedShot(pane.window, name: "serial-footer-user-disconnected")
            },
            onFailure: {
                print("UIPROBE-SERIAL user_disconnect_released=false connected=\(serialPane?.isConnected == true) footer_state=\(String(describing: serialPane?.footerView?.currentLinkState)) tail=\(serialPane?.scrollbackText(maxLines: 100).suffix(200) ?? "")")
            }))
        // Hotplug suppression: a simulated device return through the EXACT
        // hotplug entry point must NOT auto-reopen a user-released port
        // (contrast with serial-unplug-banner/reconnect legs, where the
        // device-VANISHED arm keeps the tio-style auto-reopen).
        probe.add(ProbeStep(
            name: "serial-user-disconnect-suppresses-hotplug", timeout: 8,
            action: {
                guard let pane = serialPane else { probeFail("suppress leg: pane lost") }
                // Identity matches (path fallback) — the only gate that may
                // refuse this reopen is the userDisconnected state itself.
                pane.hotplugAttached([SerialPortInfo(path: pane.setup.path)])
            },
            condition: {
                serialPane?.isConnected == false
                    && serialPane?.footerView?.currentLinkState == .userDisconnected
            },
            assert: {
                guard let pane = serialPane else { throw ProbeFailure("suppress leg: pane lost") }
                guard pane.currentTermiosForProbe() == nil else {
                    throw ProbeFailure("hotplug return reopened a user-released port")
                }
                print("UIPROBE-SERIAL user_disconnect_hotplug_suppressed=true still_released=true")
            },
            onFailure: {
                print("UIPROBE-SERIAL user_disconnect_hotplug_suppressed=false connected=\(serialPane?.isConnected == true)")
            }))
        // Pending settings while disconnected: a footer baud click updates
        // the NEXT-open settings (the wrong-baud fix path) and the footer
        // summary reflects them — with no fd to apply anything to.
        probe.add(ProbeStep(
            name: "serial-disconnected-baud-pending", timeout: 8,
            action: {
                serialPane?.footerView?.probeSelectBaud(57600)
            },
            condition: {
                serialPane?.setup.settings.baud == 57600
                    && serialPane?.footerView?.probeBaudTitle == "57600"
            },
            assert: {
                guard let pane = serialPane else { throw ProbeFailure("pending-baud leg: pane lost") }
                guard !pane.isConnected, pane.currentTermiosForProbe() == nil else {
                    throw ProbeFailure("a disconnected baud click opened the port")
                }
                guard pane.paneTitle.contains("@ 57600") else {
                    throw ProbeFailure("pending baud not reflected in the title (\(pane.paneTitle))")
                }
                print("UIPROBE-SERIAL pending_baud_while_disconnected=true footer_baud=57600 still_released=true")
            },
            onFailure: {
                print("UIPROBE-SERIAL pending_baud_while_disconnected=false settings=\(serialPane?.setup.settings.compactString ?? "-") footer=\(serialPane?.footerView?.probeBaudTitle ?? "-")")
            }))
        // Connect through the same dot toggle: reopens with the CURRENT
        // (edited-while-disconnected) settings, banner names them, traffic
        // and counters RESUME on the old totals.
        var connectRxBefore = -1
        probe.add(ProbeStep(
            name: "serial-connect-restores-traffic", timeout: 10,
            action: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    probeFail("connect leg: pane/footer lost")
                }
                connectRxBefore = pane.footerModel.rxBytes
                footer.dotButton.performClick(nil)  // toggle: now Connect
                guard pane.isConnected else {
                    probeFail("connect gesture did not reopen \(pane.setup.path)")
                }
                // Loopback across the fresh open (hex lens still on): a
                // 4-byte run written 4x, at least one renders intact.
                let bytes: [UInt8] = [0xf0, 0x0d, 0xab, 0x1e, 0xf0, 0x0d, 0xab, 0x1e,
                                      0xf0, 0x0d, 0xab, 0x1e, 0xf0, 0x0d, 0xab, 0x1e]
                _ = bytes.withUnsafeBytes { write(serialMasterFD, $0.baseAddress, $0.count) }
            },
            condition: {
                guard let pane = serialPane else { return false }
                return pane.isConnected
                    && pane.footerModel.rxBytes >= connectRxBefore + 16
                    && pane.scrollbackText(maxLines: 300).contains("f0 0d ab 1e")
            },
            assert: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    throw ProbeFailure("connect leg: pane/footer lost")
                }
                // Banner names the CURRENT settings — proof the reopen used
                // the pending 57600 edited while the port was released.
                guard pane.scrollbackText(maxLines: 300).contains("memterm: connected @ 57600-8N1") else {
                    throw ProbeFailure("connect banner missing/wrong settings")
                }
                guard var t = pane.currentTermiosForProbe(),
                      cfgetispeed(&t) == 57600, cfgetospeed(&t) == 57600 else {
                    throw ProbeFailure("reopen did not apply the pending 57600 to the fd")
                }
                // Counters RESUMED, not reset: TX untouched since before the
                // release, RX accumulated past its pre-release total.
                guard pane.footerModel.txBytes == disconnectTxBefore,
                      pane.footerModel.rxBytes >= disconnectRxBefore + 16 else {
                    throw ProbeFailure("connect reset the counters (tx=\(pane.footerModel.txBytes) want \(disconnectTxBefore); rx=\(pane.footerModel.rxBytes) want >= \(disconnectRxBefore + 16))")
                }
                // Dot + tooltip + menu title flipped back.
                guard footer.currentLinkState == .connected,
                      footer.probeDotTitle == "●",
                      footer.probeDotTooltip == "Connected — click to disconnect" else {
                    throw ProbeFailure("footer dot did not flip back to ●/disconnect (title=\(footer.probeDotTitle) tip=\(footer.probeDotTooltip))")
                }
                let titles = serialSubmenuTitles()
                guard titles.contains("Disconnect"), !titles.contains("Connect") else {
                    throw ProbeFailure("Serial submenu did not flip to Disconnect (items=\(titles))")
                }
                print("UIPROBE-SERIAL connect_restores_traffic=true reopened_baud=57600 rx_before=\(connectRxBefore) rx_after=\(pane.footerModel.rxBytes) dot=\(footer.probeDotTitle)")
                // Composited footer evidence: the green connected dot.
                probeCompositedShot(pane.window, name: "serial-footer-connected")
                // Round-trip home so later legs meet the fixture settings.
                footer.probeSelectBaud(115200)
                guard var back = pane.currentTermiosForProbe(),
                      cfgetispeed(&back) == 115200 else {
                    throw ProbeFailure("return to 115200 did not land on the fd")
                }
            },
            onFailure: {
                print("UIPROBE-SERIAL connect_restores_traffic=false connected=\(serialPane?.isConnected == true) rx=\(serialPane?.footerModel.rxBytes ?? -1) before=\(connectRxBefore) tail=\(serialPane?.scrollbackText(maxLines: 100).suffix(300) ?? "")")
            }))
        // A user must be able to CANCEL the device-vanished auto-reopen arm
        // (the machine's userDisconnect-from-reconnectingAfterLoss): when a
        // flasher owns the device, its re-enumeration must not hand the port
        // back behind the user's back. First re-arm: unplug the live session
        // again (close the master → revoked slave → liveness disconnect).
        var cancelTxBefore = -1
        var cancelRxBefore = -1
        probe.add(ProbeStep(
            name: "serial-unplug-rearms", timeout: 8,
            action: {
                guard let pane = serialPane, pane.isConnected else {
                    probeFail("rearm leg: pane not connected")
                }
                cancelTxBefore = pane.footerModel.txBytes
                cancelRxBefore = pane.footerModel.rxBytes
                _ = Darwin.close(serialMasterFD)
            },
            condition: {
                serialPane?.isConnected == false
                    && serialPane?.footerView?.currentLinkState == .reconnecting
            },
            assert: {
                guard serialPane?.awaitingDeviceReturn == true else {
                    throw ProbeFailure("second unplug did not arm auto-reopen")
                }
                // The context menu offers the cancel while the arm stands.
                let titles = serialSubmenuTitles()
                guard titles.contains("Stop Auto-Reconnect") else {
                    throw ProbeFailure("Serial submenu missing Stop Auto-Reconnect while reconnecting (items=\(titles))")
                }
                print("UIPROBE-SERIAL unplug_rearms=true menu_offers_cancel=true")
            },
            onFailure: {
                print("UIPROBE-SERIAL unplug_rearms=false connected=\(serialPane?.isConnected == true) footer_state=\(String(describing: serialPane?.footerView?.currentLinkState))")
            }))
        // Cancel through the REAL menu item's target/action dispatch (gesture
        // fidelity): the arm drops to userDisconnected, and a simulated
        // device return through the exact hotplug entry point must NOT
        // reopen. Counters and scrollback untouched — cancel ≠ close.
        probe.add(ProbeStep(
            name: "serial-cancel-auto-reconnect", timeout: 8,
            action: {
                guard let pane = serialPane, let controller = serialController,
                      let submenu = controller.contextMenu(for: pane).items
                          .first(where: { $0.title == "Serial" })?.submenu,
                      let item = submenu.items
                          .first(where: { $0.title == "Stop Auto-Reconnect" }),
                      let action = item.action else {
                    probeFail("cancel leg: Stop Auto-Reconnect item missing")
                }
                NSApp.sendAction(action, to: item.target, from: item)
            },
            condition: {
                guard let pane = serialPane else { return false }
                return pane.footerView?.currentLinkState == .userDisconnected
                    && pane.scrollbackText(maxLines: 200)
                        .contains("memterm: auto-reconnect cancelled")
            },
            assert: {
                guard let pane = serialPane, let footer = pane.footerView else {
                    throw ProbeFailure("cancel leg: pane/footer lost")
                }
                // The suppressed hotplug return: same entry point, no reopen.
                pane.hotplugAttached([SerialPortInfo(path: pane.setup.path)])
                guard !pane.isConnected, pane.currentTermiosForProbe() == nil else {
                    throw ProbeFailure("hotplug return reopened after the cancel gesture")
                }
                guard footer.probeDotTitle == "○",
                      footer.probeDotTooltip == "Disconnected — click to connect" else {
                    throw ProbeFailure("cancel did not land the hollow-dot state (title=\(footer.probeDotTitle) tip=\(footer.probeDotTooltip))")
                }
                guard pane.footerModel.txBytes == cancelTxBefore,
                      pane.footerModel.rxBytes == cancelRxBefore else {
                    throw ProbeFailure("cancel touched the lifetime counters (tx \(cancelTxBefore)->\(pane.footerModel.txBytes) rx \(cancelRxBefore)->\(pane.footerModel.rxBytes))")
                }
                guard pane.scrollbackText(maxLines: 300).contains("f0 0d ab 1e") else {
                    throw ProbeFailure("cancel lost the scrollback")
                }
                let titles = serialSubmenuTitles()
                guard titles.contains("Connect"), !titles.contains("Stop Auto-Reconnect") else {
                    throw ProbeFailure("Serial submenu did not settle on Connect after cancel (items=\(titles))")
                }
                print("UIPROBE-SERIAL cancel_auto_reconnect=true hotplug_suppressed=true dot=\(footer.probeDotTitle)")
            },
            onFailure: {
                print("UIPROBE-SERIAL cancel_auto_reconnect=false connected=\(serialPane?.isConnected == true) footer_state=\(String(describing: serialPane?.footerView?.currentLinkState)) tail=\(serialPane?.scrollbackText(maxLines: 100).suffix(200) ?? "")")
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
                // Footer on the RESTORED pane: present, gray dot (waiting on
                // the ⌘R consent gesture — never auto-open).
                guard let footer = pane.footerView,
                      footer.currentLinkState == .disconnected else {
                    throw ProbeFailure("restored serial footer missing or not disconnected-gray (state=\(String(describing: pane.footerView?.currentLinkState)))")
                }
                print("UIPROBE-SERIAL restored_footer_present=true footer_state=disconnected")
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

    // MARK: - Claude browser extension legs (stage 3: the first kit consumer)
    //
    // Fixture ~/.claude world via the MEMTERM_CLAUDE_DIR core seam (under the
    // isolated MEMTERM_STATE_DIR — the founder's real ~/.claude is never
    // involved in these legs; the read-only real-data check lives in observe
    // mode as observe-claude-real). Every mutation+assertion pair runs inside
    // ONE synchronous assert block: MemoryEngine's 2 s poll re-derives
    // pane.lastClaudeSessionId from kernel truth and must never interleave
    // with a staged fixture value.

    private func addClaudeBrowserSteps(_ probe: ProbeRunner) {
        let attnId = "aaaa1111-attn-probe"   // live (our pid), jsonl quiet 120 s → needs input
        let workId = "bbbb2222-work-probe"   // live (pid 1), jsonl fresh → working
        let doneId = "cccc3333-done-probe"   // no registry entry → done
        let fixtureRoot = MemoryEngine.baseDir
            .appendingPathComponent("claude-probe-fixture", isDirectory: true)

        func browserBits() throws -> (ExtensionHostRuntime, ClaudeBrowserExtension) {
            guard let runtime = extensionRuntime,
                  let ext = runtime.compiledInExtension(
                      id: ClaudeBrowserExtension.extensionId) as? ClaudeBrowserExtension
            else { throw ProbeFailure("claude-browser extension not compiled in") }
            return (runtime, ext)
        }

        probe.addStateful(ProbeStep(
            name: "claude-fixtures",
            assert: {
                let fm = FileManager.default
                let projDirA = fixtureRoot.appendingPathComponent("projects/-tmp-probeA")
                let projDirB = fixtureRoot.appendingPathComponent("projects/-tmp-probeB")
                let sessionsDir = fixtureRoot.appendingPathComponent("sessions")
                for dir in [projDirA, projDirB, sessionsDir] {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                func writeJsonl(_ dir: URL, id: String, cwd: String, prompt: String,
                                mtime: Date?) throws {
                    let url = dir.appendingPathComponent("\(id).jsonl")
                    let lines = "{\"type\":\"system\",\"cwd\":\"\(cwd)\",\"version\":\"9.9.9\"}\n"
                        + "{\"type\":\"last-prompt\",\"lastPrompt\":\"\(prompt)\"}"
                    try lines.write(to: url, atomically: true, encoding: .utf8)
                    if let mtime {
                        try fm.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
                    }
                }
                try writeJsonl(projDirA, id: attnId, cwd: "/tmp/probeA",
                               prompt: "probe: needs input",
                               mtime: Date(timeIntervalSinceNow: -120))
                try writeJsonl(projDirA, id: workId, cwd: "/tmp/probeA",
                               prompt: "probe: working", mtime: nil)
                try writeJsonl(projDirB, id: doneId, cwd: "/tmp/probeB",
                               prompt: "probe: finished",
                               mtime: Date(timeIntervalSinceNow: -60))
                func writeRegistry(pid: Int32, sessionId: String) throws {
                    let record = "{\"pid\":\(pid),\"sessionId\":\"\(sessionId)\",\"cwd\":\"/tmp/probeA\",\"version\":\"9.9.9\"}"
                    try record.write(to: sessionsDir.appendingPathComponent("\(pid).json"),
                                     atomically: true, encoding: .utf8)
                }
                try writeRegistry(pid: ProcessInfo.processInfo.processIdentifier,
                                  sessionId: attnId)
                try writeRegistry(pid: 1, sessionId: workId)  // launchd: always alive
                setenv("MEMTERM_CLAUDE_DIR", fixtureRoot.path, 1)
                let scans = Adapters.claudeProjectScans()
                guard scans.map(\.slug) == ["-tmp-probeA", "-tmp-probeB"] else {
                    throw ProbeFailure("fixture scan mismatch: \(scans.map(\.slug))")
                }
                print("UIPROBE-CLAUDEFIXTURE root=\(fixtureRoot.path) projects=\(scans.count)")
            }))

        // Panel opens (⌘⇧C's Window-menu item exists), lists the fixture
        // sessions grouped by REAL cwd, newest first; search narrows; the
        // empty state names the looked-in path; the content renders pixels.
        probe.addStateful(ProbeStep(
            name: "claude-browser-panel", timeout: 10,
            assert: {
                let (runtime, ext) = try browserBits()
                guard let menuItem = NSApp.windowsMenu?.items
                    .first(where: { $0.title == "Claude Sessions" }),
                      menuItem.keyEquivalent == "c",
                      menuItem.keyEquivalentModifierMask == [.command, .shift] else {
                    throw ProbeFailure("Claude Sessions (⌘⇧C) missing from the Window menu")
                }
                runtime.showPanel(id: ClaudeBrowserExtension.panelId)
                guard let window = runtime.panelWindow(id: ClaudeBrowserExtension.panelId),
                      window.isVisible, let panel = ext.probePanel else {
                    throw ProbeFailure("claude sessions panel did not open")
                }
                ext.refreshNow()
                window.layoutIfNeeded()
                let rows = panel.probeVisibleRows()
                let expected = ["project:/tmp/probeA",
                                "session:\(workId)", "session:\(attnId)",
                                "project:/tmp/probeB", "session:\(doneId)"]
                guard rows == expected else {
                    throw ProbeFailure("panel rows mismatch: \(rows) expected \(expected)")
                }
                panel.probeSetSearch("probeB")
                guard panel.probeVisibleRows() ==
                    ["project:/tmp/probeB", "session:\(doneId)"] else {
                    throw ProbeFailure("search 'probeB' did not narrow to project B: \(panel.probeVisibleRows())")
                }
                panel.probeSetSearch("zzz-no-such-session")
                let empty = panel.probeEmptyState()
                guard empty.visible, empty.path.contains("claude-probe-fixture") else {
                    throw ProbeFailure("empty state absent or missing the looked-in path: \(empty)")
                }
                panel.probeSetSearch("")
                guard panel.probeVisibleRows() == expected,
                      panel.probeEmptyState().visible == false else {
                    throw ProbeFailure("clearing the search did not restore the full list")
                }
                // Rendered half (§2.3): the panel content actually paints.
                guard let bmp = probeBitmap(panel.view) else {
                    throw ProbeFailure("panel view yielded no bitmap")
                }
                try assertRendered(bmp, region: panel.view.bounds, what: "claude panel")
                probeCompositedShot(window, name: "claude-browser-panel")
                print("UIPROBE-CLAUDEPANEL rows=\(rows.count) search_ok=true empty_state_ok=true rendered_ok=true")
            }))

        // Resume flow: openTab + stageResume — the consent-gated offer line
        // appears feed()-only in the NEW tab with the exact --resume id;
        // FR-36 claims dedupe downgrades a second stage of the same UUID to
        // an honest `claude --continue`; an invalid id can never stage.
        probe.addStateful(ProbeStep(
            name: "claude-browser-resume", timeout: 10,
            assert: { [self] in
                let (runtime, ext) = try browserBits()
                guard let panel = ext.probePanel else {
                    throw ProbeFailure("panel not built (resume leg)")
                }
                let before = Set(controllers.map(\.tabId))
                guard panel.probeSelectSession(id: doneId) else {
                    throw ProbeFailure("could not select fixture session \(doneId)")
                }
                guard panel.probeResumeSelected() else {
                    throw ProbeFailure("resume action failed to stage")
                }
                guard let fresh = controllers.first(where: { !before.contains($0.tabId) }),
                      let pane = fresh.currentPane() else {
                    throw ProbeFailure("resume did not open a new tab with a pane")
                }
                let expectedCommand = "claude --resume \(doneId)"
                guard pane.pendingResumeCommand == expectedCommand else {
                    throw ProbeFailure("pendingResumeCommand=\(pane.pendingResumeCommand ?? "nil") expected \(expectedCommand)")
                }
                // feed()-only: the offer line is IN the buffer, the command
                // armed behind ⌘R (FR-29) — the pty received nothing.
                let text = pane.scrollbackText(maxLines: 200)
                guard text.contains("press ⌘R to type: \(expectedCommand)") else {
                    throw ProbeFailure("consent-gated offer line missing from the new tab's buffer")
                }
                // FR-36: the UUID is claimed by the fresh pane now — staging
                // it again on another tab downgrades honestly.
                guard let other = controllers.first(where: { c in
                    c.tabId != fresh.tabId && c.currentPane() != nil
                        && !(c.currentPane() is SerialPaneView)
                }), let otherPane = other.currentPane() else {
                    throw ProbeFailure("no second tab for the claims-dedupe half")
                }
                let savedPending = otherPane.pendingResumeCommand
                guard runtime.host.workspace.stageResume(
                    ClaudeSessionID(raw: doneId), TabRef(tabId: other.tabId)) else {
                    throw ProbeFailure("second stageResume refused instead of downgrading")
                }
                guard otherPane.pendingResumeCommand == "claude --continue" else {
                    throw ProbeFailure("claims dedupe did not downgrade to --continue: \(otherPane.pendingResumeCommand ?? "nil")")
                }
                // Validity/denylist gate intact: garbage can never stage.
                guard !runtime.host.workspace.stageResume(
                    ClaudeSessionID(raw: "bad;$(rm -rf ~)"), TabRef(tabId: other.tabId)) else {
                    throw ProbeFailure("stageResume accepted an invalid session id")
                }
                otherPane.pendingResumeCommand = savedPending
                print("UIPROBE-CLAUDERESUME new_tab=\(fresh.tabId.prefix(8)) offer_feed_only=true resume_id_ok=true dedupe_downgrade=true invalid_refused=true")
            }))

        // Badges: working / needs-input / done from the core-side parser,
        // through the kit's tabSessions + setBadge into the EXISTING
        // activity-indicator slot (spinner / unseen dot / clear).
        probe.addStateful(ProbeStep(
            name: "claude-browser-badges", timeout: 10,
            assert: { [self] in
                let (_, ext) = try browserBits()
                guard let controller = controllers.first(where: { c in
                    c.currentPane() != nil && !(c.currentPane() is SerialPaneView)
                }), let pane = controller.currentPane() else {
                    throw ProbeFailure("no shell pane for the badge leg")
                }
                let savedCwd = pane.lastKnownCwd
                defer {
                    pane.lastClaudeSessionId = nil
                    pane.lastKnownCwd = savedCwd
                    ext.refreshNow()
                }
                pane.lastKnownCwd = "/tmp/probeA"  // slug-joins to -tmp-probeA
                pane.lastClaudeSessionId = attnId
                ext.refreshNow()
                let attn = controller.extensionBadgeForProbe()
                pane.lastClaudeSessionId = workId
                ext.refreshNow()
                let work = controller.extensionBadgeForProbe()
                pane.lastKnownCwd = "/tmp/probeB"
                pane.lastClaudeSessionId = doneId
                ext.refreshNow()
                let done = controller.extensionBadgeForProbe()
                pane.lastClaudeSessionId = nil
                ext.refreshNow()
                let cleared = controller.extensionBadgeForProbe()
                print("UIPROBE-CLAUDEBADGE attn=\(attn) work=\(work) done=\(done) cleared=\(cleared)")
                guard attn == .unseen, work == .active, done == .idle, cleared == .idle else {
                    throw ProbeFailure("badge states wrong: attn=\(attn) work=\(work) done=\(done) cleared=\(cleared) (want unseen/active/idle/idle)")
                }
            }))
    }

    // MARK: - Archive legs (founder-amended FR-56, schema v6: close =
    // archive; Forget Everything = TRUE deletion, archive included)

    private func addArchiveSteps(_ probe: ProbeRunner) {
        var doomedTabId: String?
        var doomedPaneIds: [String] = []
        var doomedWorkspaceName: String?
        // The FTS fixture: a known command written as the first doomed pane's
        // .hist (the zsh hook's exact extended-history format — the hook
        // itself can't run: probe panes execute no commands). Archived at
        // close, found by the timeline-search leg.
        let needleCommand = "timeline-probe-needle --from-hist"
        probe.addStateful(ProbeStep(
            name: "archive-on-close", timeout: 10,
            action: { [self] in
                newWindowForTab(nil)
                if let host = keyHost(), let tab = host.selectedTab {
                    doomedTabId = tab.tabId
                    doomedPaneIds = tab.allPanes().map { $0.paneId }
                    doomedWorkspaceName = memory?.store.listWorkspaces()
                        .first { $0.id == (controllers.first(where: { $0.tabId == tab.tabId })?.workspaceId ?? "") }?
                        .name
                }
                if let engine = memory, let paneId = doomedPaneIds.first,
                   let line = ShellIntegration.formatHistoryLine(
                       epoch: Int(Date().timeIntervalSince1970),
                       command: needleCommand) {
                    try? line.write(
                        to: ShellIntegration.histFileURL(dir: engine.historyDir,
                                                         paneId: paneId),
                        atomically: true, encoding: .utf8)
                }
                // The archive reads the pane's LIVE rows for its metadata,
                // so the new tab must be captured before the close.
                memory?.flushSync()
            },
            condition: { [self] in
                guard doomedTabId != nil, !doomedPaneIds.isEmpty else { return false }
                let restored = memory?.store.loadState() ?? []
                return restored.contains { win in
                    win.tabs.contains { tab in
                        doomedPaneIds.allSatisfy { tab.panes[$0] != nil }
                    }
                }
            },
            assert: { [self] in
                guard let engine = memory, let tabId = doomedTabId,
                      let doomed = controllers.first(where: { $0.tabId == tabId })
                else { throw ProbeFailure("archive leg lost its tab") }
                doomed.close()  // user close through the real funnel
                engine.store.barrier()
                // Sessions row + honest reason + frozen files + clean live rows.
                let rows = engine.store.archivedSessions(limit: 100)
                    .filter { $0.tabId == tabId }
                guard rows.count == doomedPaneIds.count,
                      rows.allSatisfy({ $0.closeReason == SessionCloseReason.userClose.rawValue })
                else {
                    throw ProbeFailure("close archived \(rows.count)/\(doomedPaneIds.count) panes (reasons \(rows.map(\.closeReason)))")
                }
                for row in rows {
                    let dir = StateStore.archiveSessionDir(engine.archiveDir, id: row.id)
                    guard FileManager.default.fileExists(
                        atPath: dir.appendingPathComponent("scrollback.txt").path) else {
                        throw ProbeFailure("archived session \(row.id) missing frozen scrollback.txt")
                    }
                    // Kit surface round-trip: the frozen text is readable.
                    guard engine.store.archivedScrollbackText(
                        id: row.id, archiveDir: engine.archiveDir) != nil else {
                        throw ProbeFailure("archivedScrollbackText nil for \(row.id)")
                    }
                }
                for paneId in doomedPaneIds {
                    if FileManager.default.fileExists(
                        atPath: engine.scrollbackURL(for: paneId).path) {
                        throw ProbeFailure("live scrollback file survived the archive move")
                    }
                }
                let livePanes = engine.store.loadState().flatMap(\.tabs)
                    .flatMap { $0.panes.keys }
                guard doomedPaneIds.allSatisfy({ !livePanes.contains($0) }) else {
                    throw ProbeFailure("live pane rows survived the archive")
                }
                print("UIPROBE-ARCHIVE sessions=\(rows.map(\.id)) reason=user-close live_clean=true")
            }))

        // The timeline legs consume the just-archived sessions; they must
        // run between archive-on-close and forget-everything (which wipes
        // the archive by design).
        addTimelineSteps(probe,
                         doomedTabId: { doomedTabId },
                         doomedPaneIds: { doomedPaneIds },
                         doomedWorkspaceName: { doomedWorkspaceName },
                         needleCommand: needleCommand)

        // Forget Everything leaves an EMPTY archive (the amended FR-56's
        // other half: explicit Forget stays TRUE deletion). Runs LAST — it
        // wipes the isolated probe state dir's memory by design.
        probe.addStateful(ProbeStep(
            name: "forget-everything-empties-archive", timeout: 10,
            assert: { [self] in
                guard let engine = memory,
                      engine.store.archivedSessionCount() > 0 else {
                    throw ProbeFailure("archive empty before Forget Everything — leg ordering broken")
                }
                let archiveDir = engine.archiveDir
                forgetEverything()
                guard let fresh = memory else { throw ProbeFailure("no engine after forget") }
                fresh.store.barrier()
                let count = fresh.store.archivedSessionCount()
                let leftovers = (try? FileManager.default.contentsOfDirectory(
                    atPath: archiveDir.path)) ?? []
                print("UIPROBE-FORGET-EVERYTHING archive_rows=\(count) archive_files=\(leftovers.count)")
                guard count == 0, leftovers.isEmpty else {
                    throw ProbeFailure("Forget Everything left archive rows=\(count) files=\(leftovers)")
                }
                // The emptied timeline explains itself (explanatory empty
                // state), captured for the founder-taste record.
                if let runtime = extensionRuntime,
                   let ext = runtime.compiledInExtension(
                       id: TimelineExtension.extensionId) as? TimelineExtension {
                    runtime.showPanel(id: TimelineExtension.panelId)
                    ext.refreshNow()
                    let window = runtime.panelWindow(id: TimelineExtension.panelId)
                    window?.layoutIfNeeded()
                    guard let panel = ext.probePanel, panel.probeEmptyState().visible,
                          panel.probeEmptyState().title == "Your timeline is empty" else {
                        throw ProbeFailure("emptied timeline lacks its explanatory empty state")
                    }
                    probeCompositedShot(window, name: "timeline-empty")
                }
            }))
    }

    // MARK: - Timeline legs (FR-43/54: the archive train's second kit
    // consumer). Registered between archive-on-close (their fixture) and
    // forget-everything (which wipes the archive by design). Same discipline
    // as the claude-browser legs: every mutation+assertion pair runs inside
    // ONE synchronous assert block so MemoryEngine's 2 s poll never
    // interleaves with a staged snapshot.

    // swiftlint:disable:next function_body_length
    private func addTimelineSteps(_ probe: ProbeRunner,
                                  doomedTabId: @escaping () -> String?,
                                  doomedPaneIds: @escaping () -> [String],
                                  doomedWorkspaceName: @escaping () -> String?,
                                  needleCommand: String) {
        func timelineBits() throws -> (ExtensionHostRuntime, TimelineExtension) {
            guard let runtime = extensionRuntime,
                  let ext = runtime.compiledInExtension(
                      id: TimelineExtension.extensionId) as? TimelineExtension
            else { throw ProbeFailure("timeline extension not compiled in") }
            return (runtime, ext)
        }
        /// The archived rows of the archive-on-close tab, newest first.
        func doomedRows() throws -> [ArchivedSessionRow] {
            guard let engine = memory, let tabId = doomedTabId() else {
                throw ProbeFailure("timeline legs lost the archived tab")
            }
            return engine.store.archivedSessions(limit: 200)
                .filter { $0.tabId == tabId }
        }

        // Panel opens (⌘⇧T Window-menu item exists), the archived sessions
        // present as cards under a Today header, newest first, attributed to
        // their workspace by name; the content renders pixels.
        probe.addStateful(ProbeStep(
            name: "timeline-panel", timeout: 10,
            assert: {
                let (runtime, ext) = try timelineBits()
                guard let menuItem = NSApp.windowsMenu?.items
                    .first(where: { $0.title == "Timeline" }),
                      menuItem.keyEquivalent == "t",
                      menuItem.keyEquivalentModifierMask == [.command, .shift] else {
                    throw ProbeFailure("Timeline (⌘⇧T) missing from the Window menu")
                }
                runtime.showPanel(id: TimelineExtension.panelId)
                guard let window = runtime.panelWindow(id: TimelineExtension.panelId),
                      window.isVisible, let panel = ext.probePanel else {
                    throw ProbeFailure("timeline panel did not open")
                }
                ext.refreshNow()
                window.layoutIfNeeded()
                let rows = panel.probeVisibleRows()
                // Sessions lead with Today; in a restored world a parked
                // workspace's card section (FR-54, seeded by --smoke=save)
                // legitimately precedes it — but ONLY that section may.
                guard let todayIndex = rows.firstIndex(of: "header:Today") else {
                    throw ProbeFailure("timeline has no Today header: \(rows.prefix(4))")
                }
                let leading = rows[..<todayIndex]
                guard leading.allSatisfy({ $0 == "header:Parked Workspaces"
                        || $0.hasPrefix("workspace:") }) else {
                    throw ProbeFailure("unexpected rows before Today: \(Array(leading))")
                }
                let archived = try doomedRows()
                guard !archived.isEmpty else {
                    throw ProbeFailure("no archived sessions for the timeline leg")
                }
                guard let wsName = doomedWorkspaceName() else {
                    throw ProbeFailure("timeline leg lost the workspace attribution fixture")
                }
                // Newest-first: the archive-on-close sessions are the newest
                // archive rows, so the first session row is theirs — and it
                // carries the workspace attribution.
                guard rows.count > todayIndex + 1,
                      rows[todayIndex + 1] == "session:\(archived[0].id) ws=\(wsName)" else {
                    throw ProbeFailure("first card wrong: \(rows.prefix(todayIndex + 2)) expected session:\(archived[0].id) ws=\(wsName)")
                }
                for row in archived {
                    guard rows.contains("session:\(row.id) ws=\(wsName)") else {
                        throw ProbeFailure("archived session \(row.id) missing from timeline rows")
                    }
                }
                // Rendered half (§2.3): the panel content actually paints.
                guard let bmp = probeBitmap(panel.view) else {
                    throw ProbeFailure("timeline view yielded no bitmap")
                }
                try assertRendered(bmp, region: panel.view.bounds, what: "timeline panel")
                probeCompositedShot(window, name: "timeline-panel")
                print("UIPROBE-TIMELINE rows=\(rows.count) today_first=true attribution=\(wsName)")
            }))

        // Search: the FTS index over archived COMMAND history finds the
        // .hist fixture command; a garbage query shows the no-matches empty
        // state; clearing restores the full list.
        probe.addStateful(ProbeStep(
            name: "timeline-search", timeout: 10,
            assert: {
                let (runtime, ext) = try timelineBits()
                guard let panel = ext.probePanel else {
                    throw ProbeFailure("panel not built (search leg)")
                }
                guard let needlePane = doomedPaneIds().first else {
                    throw ProbeFailure("no fixture pane (search leg)")
                }
                let expected = try doomedRows().filter { $0.paneId == needlePane }
                guard expected.count == 1 else {
                    throw ProbeFailure("fixture pane archived \(expected.count) rows")
                }
                // Kit-surface truth first: the card carries the command as
                // its preview (last command wins).
                let hits = runtime.host.archive.search("timeline-probe-needle")
                guard hits.map(\.id.raw) == [String(expected[0].id)],
                      hits[0].preview == needleCommand else {
                    throw ProbeFailure("archive.search mismatch: \(hits.map { "\($0.id.raw):\($0.preview)" })")
                }
                // Panel search narrows to exactly that card.
                panel.probeSetSearch("timeline-probe-needle")
                let rows = panel.probeVisibleRows()
                guard rows.count == 2, rows[0] == "header:Today",
                      rows[1].hasPrefix("session:\(expected[0].id) ") else {
                    throw ProbeFailure("search rows wrong: \(rows)")
                }
                let window = runtime.panelWindow(id: TimelineExtension.panelId)
                window?.layoutIfNeeded()
                probeCompositedShot(window, name: "timeline-search-hit")
                panel.probeSetSearch("zzz-no-such-command")
                let empty = panel.probeEmptyState()
                guard empty.visible, empty.title == "No matches" else {
                    throw ProbeFailure("no-matches empty state absent: \(empty)")
                }
                window?.layoutIfNeeded()
                probeCompositedShot(window, name: "timeline-empty-no-matches")
                panel.probeSetSearch("")
                guard panel.probeEmptyState().visible == false,
                      panel.probeVisibleRows().count > 2 else {
                    throw ProbeFailure("clearing the search did not restore the list")
                }
                print("UIPROBE-TIMELINE-SEARCH hit=\(expected[0].id) preview_ok=true empty_state_ok=true")
            }))

        // Reopen Here: a fresh tab opens and receives the frozen scrollback
        // as a feed()-only ghost with the honest divider line.
        probe.addStateful(ProbeStep(
            name: "timeline-reopen-ghost", timeout: 10,
            assert: { [self] in
                let (_, ext) = try timelineBits()
                guard let panel = ext.probePanel else {
                    throw ProbeFailure("panel not built (reopen leg)")
                }
                guard let target = try doomedRows().first else {
                    throw ProbeFailure("no archived session to reopen")
                }
                panel.probeSetSearch("")
                guard panel.probeSelectSession(id: String(target.id)) else {
                    throw ProbeFailure("could not select archived session \(target.id)")
                }
                let before = Set(controllers.map(\.tabId))
                guard panel.probeReopenSelected() else {
                    throw ProbeFailure("Reopen Here failed")
                }
                guard let fresh = controllers.first(where: { !before.contains($0.tabId) }),
                      let pane = fresh.currentPane() else {
                    throw ProbeFailure("reopen did not open a new tab with a pane")
                }
                let text = pane.scrollbackText(maxLines: 400)
                guard text.contains("── restored — "), pane.restoredDividerCount >= 1 else {
                    throw ProbeFailure("ghost divider missing from the reopened tab")
                }
                print("UIPROBE-TIMELINE-REOPEN new_tab=\(fresh.tabId.prefix(8)) session=\(target.id) ghost_divider=true")
            }))

        // Resume: an archived claude session's card warrants Resume; the
        // action runs the SAME consent-gated stageResume flow — offer line
        // feed()-only in the new tab, command armed behind ⌘R, nothing
        // reaches the pty.
        var resumeTabId: String?
        var resumePaneId: String?
        let resumeSessionUUID = "dddd4444-timeline-probe"
        probe.addStateful(ProbeStep(
            name: "timeline-resume", timeout: 10,
            action: { [self] in
                newWindowForTab(nil)
                if let host = keyHost(), let tab = host.selectedTab {
                    resumeTabId = tab.tabId
                    resumePaneId = tab.allPanes().first?.paneId
                }
                memory?.flushSync()
            },
            condition: { [self] in
                guard let paneId = resumePaneId else { return false }
                let restored = memory?.store.loadState() ?? []
                return restored.contains { win in
                    win.tabs.contains { $0.panes[paneId] != nil }
                }
            },
            assert: { [self] in
                let (runtime, ext) = try timelineBits()
                guard let engine = memory, let tabId = resumeTabId,
                      let paneId = resumePaneId, let panel = ext.probePanel,
                      let doomed = controllers.first(where: { $0.tabId == tabId })
                else { throw ProbeFailure("resume leg lost its fixture tab") }
                // Stage the claude snapshot and close INSIDE one synchronous
                // block (writer-queue ordering lands the snapshot before the
                // archive reads it; the 2 s poll cannot interleave).
                engine.store.upsertSnapshot(paneId, exe: "claude", argv: ["claude"],
                                            pid: 0, adapter: ClaudeAdapter.name,
                                            adapterState: ["sessionId": resumeSessionUUID])
                doomed.close()
                engine.store.barrier()
                let rows = engine.store.archivedSessions(limit: 50)
                    .filter { $0.tabId == tabId }
                guard rows.count == 1 else {
                    throw ProbeFailure("resume fixture archived \(rows.count) rows")
                }
                // The kit card carries the resume warrant, resolved core-side.
                guard let card = runtime.host.archive
                    .query(ArchiveQuery(limit: 50))
                    .first(where: { $0.id.raw == String(rows[0].id) }),
                      card.claudeSessionId?.raw == resumeSessionUUID,
                      card.kind == .claude else {
                    throw ProbeFailure("archived claude card lacks the resume warrant")
                }
                ext.refreshNow()
                guard panel.probeSelectSession(id: String(rows[0].id)) else {
                    throw ProbeFailure("could not select the claude card")
                }
                let actions = panel.probeActionState()
                guard actions.resumeHidden == false else {
                    throw ProbeFailure("Resume hidden on a claude card")
                }
                let before = Set(controllers.map(\.tabId))
                guard panel.probeResumeSelected() else {
                    throw ProbeFailure("Resume failed to stage")
                }
                guard let fresh = controllers.first(where: { !before.contains($0.tabId) }),
                      let pane = fresh.currentPane() else {
                    throw ProbeFailure("resume did not open a new tab")
                }
                let expectedCommand = "claude --resume \(resumeSessionUUID)"
                guard pane.pendingResumeCommand == expectedCommand else {
                    throw ProbeFailure("pendingResumeCommand=\(pane.pendingResumeCommand ?? "nil") expected \(expectedCommand)")
                }
                let text = pane.scrollbackText(maxLines: 400)
                guard text.contains("press ⌘R to type: \(expectedCommand)") else {
                    throw ProbeFailure("consent-gated offer line missing from the resumed tab")
                }
                guard text.contains("── restored — ") else {
                    throw ProbeFailure("resume tab missing the ghost divider")
                }
                print("UIPROBE-TIMELINE-RESUME card=\(rows[0].id) offer_feed_only=true resume_warrant=true")
            }))

        // Per-card Forget: TRUE deletion of exactly that session — row, FTS
        // entry, frozen files — while every other archived session survives.
        probe.addStateful(ProbeStep(
            name: "timeline-forget-card", timeout: 10,
            assert: { [self] in
                let (runtime, ext) = try timelineBits()
                guard let engine = memory, let panel = ext.probePanel else {
                    throw ProbeFailure("panel not built (forget leg)")
                }
                guard let needlePane = doomedPaneIds().first,
                      let target = try doomedRows().first(where: { $0.paneId == needlePane })
                else { throw ProbeFailure("forget leg lost its target session") }
                let countBefore = engine.store.archivedSessionCount()
                let targetDir = StateStore.archiveSessionDir(engine.archiveDir,
                                                             id: target.id)
                guard FileManager.default.fileExists(atPath: targetDir.path) else {
                    throw ProbeFailure("target session has no archive dir to delete")
                }
                panel.probeSetSearch("")
                guard panel.probeSelectSession(id: String(target.id)),
                      panel.probeForgetSelected() else {
                    throw ProbeFailure("could not Forget the selected card")
                }
                engine.store.barrier()
                guard engine.store.archivedSession(id: target.id) == nil else {
                    throw ProbeFailure("forgotten session row survived")
                }
                guard !FileManager.default.fileExists(atPath: targetDir.path) else {
                    throw ProbeFailure("forgotten session's frozen files survived")
                }
                guard engine.store.archivedSessionCount() == countBefore - 1 else {
                    throw ProbeFailure("Forget deleted more than one session (\(countBefore) → \(engine.store.archivedSessionCount()))")
                }
                guard runtime.host.archive.search("timeline-probe-needle").isEmpty else {
                    throw ProbeFailure("FTS entry survived the per-card Forget")
                }
                ext.refreshNow()
                guard !panel.probeVisibleRows()
                    .contains(where: { $0.hasPrefix("session:\(target.id) ") }) else {
                    throw ProbeFailure("forgotten card still rendered")
                }
                print("UIPROBE-TIMELINE-FORGET session=\(target.id) rows=\(countBefore)→\(countBefore - 1) fts_clean=true files_clean=true")
            }))

        // FR-54: a parked workspace is one reopenable card; opening it runs
        // the standard unpark funnel (journal → resurrect).
        var parkedWorkspaceId: String?
        var previousWorkspaceId: String?
        probe.addStateful(ProbeStep(
            name: "timeline-parked-workspace", timeout: 10,
            action: { [self] in
                guard let engine = memory else { return }
                previousWorkspaceId = activeWorkspaceId
                parkedWorkspaceId = engine.store.createWorkspace(
                    name: "TimelinePark", color: "#0a84ff")
                if let id = parkedWorkspaceId {
                    engine.store.setWorkspaceParked(id, parked: true)
                }
                engine.store.barrier()
            },
            assert: { [self] in
                let (runtime, ext) = try timelineBits()
                guard let engine = memory, let panel = ext.probePanel,
                      let parkedId = parkedWorkspaceId,
                      let previousId = previousWorkspaceId else {
                    throw ProbeFailure("parked-workspace fixture missing")
                }
                // Kit surface: the parked workspace lists as a card.
                guard runtime.host.workspace.parkedWorkspaces()
                    .contains(where: { $0.id.raw == parkedId }) else {
                    throw ProbeFailure("parkedWorkspaces does not list the fixture")
                }
                ext.refreshNow()
                let rows = panel.probeVisibleRows()
                // The parked section leads; the fixture's card sits in it
                // (a restored world's seed may park workspaces of its own —
                // switcher order within the section).
                guard rows.first == "header:Parked Workspaces",
                      let cardIndex = rows.firstIndex(of: "workspace:TimelinePark"),
                      let todayIndex = rows.firstIndex(of: "header:Today"),
                      cardIndex < todayIndex else {
                    throw ProbeFailure("parked card not in the leading section: \(rows.prefix(5))")
                }
                guard panel.probeSelectWorkspace(name: "TimelinePark") else {
                    throw ProbeFailure("could not select the parked card")
                }
                guard panel.probeActionState().reopenTitle == "Open Workspace" else {
                    throw ProbeFailure("primary action did not follow the workspace card")
                }
                guard panel.probeOpenSelectedWorkspace() else {
                    throw ProbeFailure("openWorkspace refused the parked card")
                }
                guard activeWorkspaceId == parkedId,
                      engine.store.listWorkspaces()
                          .first(where: { $0.id == parkedId })?.isParked == false,
                      controllers.contains(where: { $0.workspaceId == parkedId }) else {
                    throw ProbeFailure("opening the parked card did not unpark+present it")
                }
                // Unparked → its card leaves the timeline.
                ext.refreshNow()
                guard !panel.probeVisibleRows().contains("workspace:TimelinePark") else {
                    throw ProbeFailure("unparked workspace still renders as a parked card")
                }
                switchToWorkspace(previousId)  // leave the world as found
                print("UIPROBE-TIMELINE-PARKED workspace=\(parkedId.prefix(8)) reopened=true card_cleared=true")
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

    // -----------------------------------------------------------------
    // Quake-style drop-down terminal (founder ask 2026-09-09). The hotkey
    // itself is never registered in automated runs (a real system-wide
    // hotkey would fire into the founder's session); the legs drive the
    // controller the hotkey drives. Quiet runs place the panel on a virtual
    // off-screen "screen", so frames are asserted against the same
    // DropdownLayout math with that screen — geometry, not pixels.
    // -----------------------------------------------------------------
    private func addDropdownSteps(_ probe: ProbeRunner) {
        func dropdownConfig(edge: String = "top", width: Double = 1.0, height: Double = 0.5,
                            align: String = "center", hideOnFocusLoss: Bool = true) -> Config {
            var c = config
            c.dropdownEnabled = true
            c.dropdownHotkey = "ctrl+`"
            c.dropdownEdge = edge
            c.dropdownWidth = width
            c.dropdownHeight = height
            c.dropdownAlign = align
            c.dropdownHideOnFocusLoss = hideOnFocusLoss
            c.dropdownAnimationMs = 0
            return c
        }
        var panelTab: TerminalWindowController?
        let originalConfig = config

        // Toggle ON: a .dropdown host for the active workspace appears at the
        // configured frame, key, with a live tab; no hotkey registered here.
        probe.add(ProbeStep(
            name: "dropdown-show", timeout: 10,
            action: { [self] in
                applyConfigLive(dropdownConfig())
                dropdown.toggle()
            },
            condition: { [self] in
                dropdown.panelHost?.window?.isVisible == true
                    && dropdown.panelHost?.selectedTab?.allPanes().first?.process?.running == true
            },
            assert: { [self] in
                guard let host = dropdown.panelHost, let window = host.window else {
                    throw ProbeFailure("no drop-down panel after toggle")
                }
                panelTab = host.selectedTab
                let expected = dropdown.targetFrame(config)
                let off = max(abs(window.frame.minX - expected.minX), abs(window.frame.minY - expected.minY),
                              abs(window.frame.width - expected.width), abs(window.frame.height - expected.height))
                print("UIPROBE-DROPDOWN show=true role=dropdown ws_is_active=\(host.workspaceId == activeWorkspaceId) frame=\(Int(window.frame.minX)),\(Int(window.frame.minY)),\(Int(window.frame.width))x\(Int(window.frame.height)) expected_off=\(String(format: "%.1f", off)) level_floating=\(window.level == .floating) movable=\(window.isMovable) hotkey_registered=\(dropdown.probeRegisteredHotkey ?? "none")")
                guard host.isDropdown, host.workspaceId == activeWorkspaceId, off <= 1 else {
                    throw ProbeFailure("panel geometry/role wrong: off=\(off) role=\(host.isDropdown) ws=\(host.workspaceId ?? "nil")")
                }
                guard window.level == .floating, !window.isMovable else {
                    throw ProbeFailure("panel must float above windows and not be movable")
                }
                guard dropdown.probeRegisteredHotkey == nil else {
                    throw ProbeFailure("a global hotkey was registered inside an automated run")
                }
            }))

        // Toggle OFF: slides off its edge and orders out; the host and its
        // live tab stay (the panel is hidden, not closed).
        probe.add(ProbeStep(
            name: "dropdown-hide", timeout: 8,
            action: { [self] in dropdown.toggle() },
            condition: { [self] in dropdown.panelHost?.window?.isVisible == false },
            assert: { [self] in
                guard let host = dropdown.panelHost, let window = host.window, let tab = panelTab else {
                    throw ProbeFailure("panel host vanished on hide")
                }
                let hidden = DropdownLayout.hiddenFrame(target: dropdown.targetFrame(config),
                                                        screen: dropdown.screenFrame(config),
                                                        edge: DropdownLayout.Edge(rawValue: config.dropdownEdge) ?? .top)
                let parked = abs(window.frame.minY - hidden.minY) <= 1 && abs(window.frame.minX - hidden.minX) <= 1
                let alive = controllers.contains { $0 === tab } && host.tabs.contains { $0 === tab }
                    && tab.allPanes().first?.process?.running == true
                print("UIPROBE-DROPDOWN hide=true parked_off_edge=\(parked) tab_alive=\(alive)")
                guard parked, alive else { throw ProbeFailure("hide must park off-edge and keep the tab live") }
            }))

        // Every edge and placement lands where DropdownLayout says.
        probe.add(ProbeStep(
            name: "dropdown-edges",
            assert: { [self] in
                for (edge, width, height, align) in [("left", 0.35, 1.0, "center"), ("right", 0.4, 0.8, "center"),
                                                     ("top", 0.5, 0.4, "left"), ("top", 0.6, 0.3, "right")] {
                    applyConfigLive(dropdownConfig(edge: edge, width: width, height: height, align: align))
                    dropdown.show()
                    guard let window = dropdown.panelHost?.window, window.isVisible else {
                        throw ProbeFailure("edge \(edge): panel not shown")
                    }
                    let expected = dropdown.targetFrame(config)
                    let off = max(abs(window.frame.minX - expected.minX), abs(window.frame.minY - expected.minY),
                                  abs(window.frame.width - expected.width), abs(window.frame.height - expected.height))
                    print("UIPROBE-DROPDOWN edge=\(edge) align=\(align) size=\(width)x\(height) frame=\(Int(window.frame.minX)),\(Int(window.frame.minY)),\(Int(window.frame.width))x\(Int(window.frame.height)) off=\(String(format: "%.1f", off))")
                    guard off <= 1 else { throw ProbeFailure("edge \(edge) align \(align): frame off by \(off)") }
                    dropdown.hide()
                    guard window.isVisible == false else { throw ProbeFailure("edge \(edge): hide left it visible") }
                }
                applyConfigLive(dropdownConfig())
            }))

        // hide_on_focus_loss: another window taking key slides the panel away;
        // with the option off it stays.
        // Quiet runs are never the ACTIVE app, so a real key-window
        // transition may not happen (flaked on a busy desktop); they drive
        // the window-delegate entry point the transition calls. Visible
        // runs take the real path.
        func loseFocus() {
            if ProbeSupport.visible {
                hosts.first { !$0.isDropdown && $0.workspaceId == activeWorkspaceId }?.focusWindow()
            } else if let panel = dropdown.panelHost {
                dropdown.panelResignedKey(panel)
            }
        }
        probe.add(ProbeStep(
            name: "dropdown-focus-loss", timeout: 8,
            action: { [self] in
                dropdown.show()
                loseFocus()
            },
            condition: { [self] in dropdown.panelHost?.window?.isVisible == false },
            assert: { [self] in
                print("UIPROBE-DROPDOWN focus_loss_hides=true real_key_path=\(ProbeSupport.visible)")
                applyConfigLive(dropdownConfig(hideOnFocusLoss: false))
                dropdown.show()
                loseFocus()
                let stayed = dropdown.panelHost?.window?.isVisible == true
                print("UIPROBE-DROPDOWN focus_loss_off_stays=\(stayed)")
                guard stayed else { throw ProbeFailure("hide_on_focus_loss=false must keep the panel") }
                dropdown.hide()
                applyConfigLive(dropdownConfig())
            }))

        // Double-tap trigger: with "double-tap ctrl", two clean quick taps
        // fed into the controller toggle the panel; slow taps and a
        // shortcut in between (⌃C) do not; no event tap runs in a probe.
        probe.add(ProbeStep(
            name: "dropdown-double-tap",
            assert: { [self] in
                var c = dropdownConfig()
                c.dropdownHotkey = "double-tap ctrl"
                applyConfigLive(c)
                guard dropdown.probeTrigger == "double-tap ctrl", !dropdown.doubleTapIsGlobal else {
                    throw ProbeFailure("double-tap trigger not honored (trigger=\(dropdown.probeTrigger ?? "nil") global=\(dropdown.doubleTapIsGlobal))")
                }
                let wasShowing = dropdown.isShowing
                let t0: TimeInterval = 100
                dropdown.tap(.control, pressed: true, at: t0)
                dropdown.tap(.control, pressed: false, at: t0 + 0.05)
                dropdown.tap(.control, pressed: true, at: t0 + 0.2)
                dropdown.tap(.control, pressed: false, at: t0 + 0.25)
                let toggled = dropdown.isShowing != wasShowing
                // Slow taps: nothing.
                let before = dropdown.isShowing
                dropdown.tap(.control, pressed: true, at: t0 + 2)
                dropdown.tap(.control, pressed: false, at: t0 + 2.1)
                dropdown.tap(.control, pressed: true, at: t0 + 3)
                dropdown.tap(.control, pressed: false, at: t0 + 3.1)
                let slowStayed = dropdown.isShowing == before
                // ⌃C between taps: a shortcut, not a tap.
                dropdown.tap(.control, pressed: true, at: t0 + 5)
                dropdown.otherKey()
                dropdown.tap(.control, pressed: false, at: t0 + 5.1)
                dropdown.tap(.control, pressed: true, at: t0 + 5.2)
                dropdown.tap(.control, pressed: false, at: t0 + 5.25)
                let shortcutStayed = dropdown.isShowing == before
                // A different modifier's tap never counts.
                dropdown.tap(.option, pressed: true, at: t0 + 7)
                dropdown.tap(.option, pressed: false, at: t0 + 7.05)
                dropdown.tap(.option, pressed: true, at: t0 + 7.1)
                dropdown.tap(.option, pressed: false, at: t0 + 7.15)
                let otherStayed = dropdown.isShowing == before
                print("UIPROBE-DROPDOWN double_tap_toggles=\(toggled) slow_ignored=\(slowStayed) shortcut_ignored=\(shortcutStayed) other_key_ignored=\(otherStayed) global_tap=\(dropdown.doubleTapIsGlobal)")
                guard toggled, slowStayed, shortcutStayed, otherStayed else {
                    throw ProbeFailure("double-tap recognition wrong")
                }
                if dropdown.isShowing { dropdown.hide() }
                applyConfigLive(dropdownConfig())
            }))

        // Settings size fields (founder 2026-09-09: "nothing works unless we
        // hit enter", "we can enter letters"): typing digits through the
        // real field editor applies WITHOUT Enter; letters never land.
        probe.add(ProbeStep(
            name: "dropdown-settings-size-typing",
            assert: { [self] in
                let settings = SettingsWindowController(app: self)
                let typed = settings.probeTypeDropdownWidth("40")
                let letters = settings.probeTypeDropdownWidth("ab")
                print("UIPROBE-DROPDOWN settings_typed_field=\(typed.field) width_after_typing=\(typed.width) letters_field=\"\(letters.field)\" width_after_letters=\(letters.width)")
                let speed = settings.probeSetDropdownSpeed(320)
                print("UIPROBE-DROPDOWN speed_readout=\(speed.readout) speed_config_ms=\(speed.configMs)")
                settings.window?.orderOut(nil)
                guard speed.readout == "320 ms", speed.configMs == 320 else {
                    throw ProbeFailure("slide speed slider did not apply (\(speed.readout), \(speed.configMs))")
                }
                guard typed.field == "40", abs(typed.width - 0.4) < 0.001 else {
                    throw ProbeFailure("typing 40 without Enter did not apply (field=\(typed.field) width=\(typed.width))")
                }
                guard letters.field.isEmpty || letters.field == "40", abs(letters.width - 0.4) < 0.001 else {
                    throw ProbeFailure("letters landed in the percent field (\"\(letters.field)\")")
                }
                applyConfigLive(dropdownConfig())
            }))

        // Journal: the panel captures as a window with role "dropdown".
        probe.add(ProbeStep(
            name: "dropdown-journal-role",
            assert: { [self] in
                guard let engine = memory, let tab = panelTab else { throw ProbeFailure("no engine/tab") }
                engine.flushSync()
                let rows = engine.store.loadState(workspaceId: activeWorkspaceId)
                let panelRow = rows.first { $0.isDropdown }
                let normal = rows.filter { !$0.isDropdown }.count
                print("UIPROBE-DROPDOWN journaled_role=\(panelRow != nil) normal_windows=\(normal) panel_tabs=\(panelRow?.tabs.count ?? -1)")
                guard let panelRow, panelRow.tabs.count == 1, normal >= 1 else {
                    throw ProbeFailure("panel not journaled with role dropdown (rows: \(rows.map { $0.role ?? "nil" }))")
                }
                _ = tab
            }))

        // FR-59: the panel belongs to its workspace — a switch hides it, never
        // swaps it into a normal window; the other workspace gets its own
        // panel; switching back finds the first panel again, same tab.
        var otherWorkspace: String?
        probe.addStateful(ProbeStep(
            name: "dropdown-workspace-switch", timeout: 12,
            action: { [self] in
                dropdown.show()
                otherWorkspace = createWorkspace(named: "Dropdown Probe")
                if let id = otherWorkspace { switchToWorkspace(id) }
            },
            condition: { [self] in
                guard let id = otherWorkspace else { return false }
                return activeWorkspaceId == id
                    && hosts.contains { $0.workspaceId == id && !$0.isDropdown && $0.window?.isVisible == true }
                    && hosts.filter { $0.isDropdown }.allSatisfy { $0.window?.isVisible != true }
            },
            assert: { [self] in
                guard let id = otherWorkspace, let tab = panelTab else { throw ProbeFailure("switch setup lost") }
                let firstPanel = hosts.first { $0.isDropdown && $0.tabs.contains { $0 === tab } }
                guard let firstPanel, firstPanel.workspaceId == StateStore.defaultWorkspaceId else {
                    throw ProbeFailure("the default workspace's panel was swapped or re-homed")
                }
                dropdown.toggle()  // the OTHER workspace's own panel
                guard let second = dropdown.panelHost, second !== firstPanel, second.workspaceId == id,
                      second.window?.isVisible == true else {
                    throw ProbeFailure("the other workspace did not get its own panel")
                }
                dropdown.hide()
                switchToWorkspace(StateStore.defaultWorkspaceId)
                guard activeWorkspaceId == StateStore.defaultWorkspaceId,
                      dropdown.panelHost === firstPanel, firstPanel.window?.isVisible != true else {
                    throw ProbeFailure("switching back did not find the first panel hidden")
                }
                dropdown.toggle()
                let same = dropdown.panelHost === firstPanel && firstPanel.selectedTab === tab
                    && firstPanel.window?.isVisible == true
                print("UIPROBE-DROPDOWN switch_hides=true per_workspace_panels=true back_same_tab=\(same)")
                guard same else { throw ProbeFailure("panel after switch-back is not the same tab") }
                dropdown.hide()
                applyConfigLive(originalConfig)
            }))
    }

    /// Founder 2026-09-09: every tab closed (user closes), then the hotkey —
    /// a terminal must come back, in the Default workspace. Runs LAST: it
    /// empties the app (probe runs never auto-quit).
    private func addDropdownAfterCloseAllSteps(_ probe: ProbeRunner) {
        probe.addStateful(ProbeStep(
            name: "dropdown-after-close-all", timeout: 15,
            action: { [self] in
                var c = config
                c.dropdownEnabled = true
                c.dropdownAnimationMs = 0
                applyConfigLive(c)
                // Make a NON-default workspace active first, so the fallback
                // to Default is exercised (its last user close removes it).
                if let id = createWorkspace(named: "Close-all Probe") { switchToWorkspace(id) }
                for controller in controllers { controller.close() }
            },
            condition: { [self] in controllers.isEmpty && hosts.allSatisfy { $0.tabs.isEmpty } },
            assert: { [self] in
                let wsBefore = activeWorkspaceId
                dropdown.toggle()
                guard let host = dropdown.panelHost, let tab = host.selectedTab,
                      host.window?.isVisible == true else {
                    throw ProbeFailure("hotkey after closing everything produced no panel")
                }
                let list = memory?.store.listWorkspaces() ?? []
                let inDefault = host.workspaceId == StateStore.defaultWorkspaceId
                    && activeWorkspaceId == StateStore.defaultWorkspaceId
                    && list.contains { $0.id == StateStore.defaultWorkspaceId && !$0.isParked }
                let chips = keyHost()?.workspaceBar?.chipTitlesForProbe() ?? []
                print("UIPROBE-DROPDOWN close_all_then_hotkey=true active_before=\(wsBefore == StateStore.defaultWorkspaceId ? "default" : "other") panel_in_default=\(inDefault) tab_live=\(tab.allPanes().first != nil) workspaces=\(list.map(\.name)) chips=\(chips)")
                guard inDefault else {
                    throw ProbeFailure("panel after close-all is not in an active Default workspace (ws=\(host.workspaceId ?? "nil") active=\(activeWorkspaceId) list=\(list.map(\.name)))")
                }
            }))
    }

    private func addTabGestureSteps(_ probe: ProbeRunner) {
        // Hover-✕: the strip's close button through the REAL button action —
        // a USER close, so FR-56 forgets its rows at the gesture.
        // confirm_close_tab (founder 2026-09-09): with the default ON, the ✕
        // opens a confirmation SHEET on the host window carrying a "Don't
        // ask me again" box. The leg checks that box and presses Close Tab
        // through the sheet's real buttons; the tab must close AND the
        // setting must flip to false in memory and in config.toml.
        var confirmDoomed: TerminalWindowController?
        var confirmBefore = -1
        probe.addStateful(ProbeStep(
            name: "close-x-confirm-sheet", timeout: 10,
            action: { [self] in
                guard let host = keyHost(), let window = host.window else {
                    probeFail("no host (confirm-sheet leg)")
                }
                guard config.confirmCloseTab else {
                    probeFail("confirm_close_tab must default ON for this leg (config says off)")
                }
                newWindowForTab(nil)
                guard let doomed = host.selectedTab else { probeFail("confirm leg: no new tab") }
                confirmDoomed = doomed
                memory?.flushSync()
                confirmBefore = memory?.store.counts().tabs ?? -1
                let clicked = host.tabStrip.probeClickClose(of: doomed.tabId)
                guard clicked, let sheet = window.attachedSheet, let root = sheet.contentView else {
                    probeFail("✕ with confirm_close_tab on did not open the confirmation sheet")
                }
                // The tab must still be alive behind the sheet.
                guard controllers.contains(where: { $0 === doomed }) else {
                    probeFail("tab closed BEFORE the confirmation was answered")
                }
                func buttons(_ view: NSView) -> [NSButton] {
                    var out: [NSButton] = []
                    if let b = view as? NSButton { out.append(b) }
                    for sub in view.subviews { out += buttons(sub) }
                    return out
                }
                let all = buttons(root)
                guard let suppress = all.first(where: { $0.title == "Don't ask me again" }),
                      let closeButton = all.first(where: { $0.title == "Close Tab" }),
                      all.contains(where: { $0.title == "Cancel" }) else {
                    probeFail("confirmation sheet lacks its controls: \(all.map(\.title))")
                }
                suppress.state = .on
                print("UIPROBE-CLOSE-CONFIRM sheet=true buttons=\(all.map(\.title)) suppress_checked=true")
                closeButton.performClick(nil)
            },
            condition: { [self] in
                guard let doomed = confirmDoomed else { return false }
                return !controllers.contains { $0 === doomed }
                    && keyHost()?.window?.attachedSheet == nil
            },
            assert: { [self] in
                memory?.store.barrier()
                let afterTabs = memory?.store.counts().tabs ?? -1
                let onDisk = (try? String(contentsOf: Config.configURL, encoding: .utf8)) ?? ""
                let saved = onDisk.contains("confirm_close_tab = false")
                print("UIPROBE-CLOSE-CONFIRM closed=true rows_forgotten=\(afterTabs == confirmBefore - 1) setting_now=\(config.confirmCloseTab) saved_false=\(saved)")
                guard afterTabs == confirmBefore - 1 else {
                    throw ProbeFailure("confirmed close did not archive the tab's rows (FR-56)")
                }
                guard !config.confirmCloseTab, saved else {
                    throw ProbeFailure("\"Don't ask me again\" did not turn confirm_close_tab off (memory=\(config.confirmCloseTab) disk=\(saved))")
                }
            }))

        // Hover-✕ with the confirmation now suppressed: closes immediately,
        // no sheet — the "don't ask again" actually took.
        probe.addStateful(ProbeStep(
            name: "hover-x-close", timeout: 8,
            assert: { [self] in
                guard let host = keyHost() else { throw ProbeFailure("no host (close-x leg)") }
                guard !config.confirmCloseTab else {
                    throw ProbeFailure("close-x leg expects confirm_close_tab off after the sheet leg")
                }
                newWindowForTab(nil)
                guard let doomed = host.selectedTab else {
                    throw ProbeFailure("close-x leg: no new tab")
                }
                memory?.flushSync()
                let beforeTabs = memory?.store.counts().tabs ?? -1
                let clicked = host.tabStrip.probeClickClose(of: doomed.tabId)
                guard host.window?.attachedSheet == nil else {
                    throw ProbeFailure("a confirmation sheet appeared although confirm_close_tab is off")
                }
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

        // ⌘W on a single-pane tab is a TAB close, so it asks too (founder
        // 2026-09-09) — and this leg takes the CANCEL path the ✕ leg does
        // not: the tab must survive and the setting must stay untouched.
        // Then, with the setting off again, ⌘W closes the tab with no sheet.
        var cmdWTab: TerminalWindowController?
        probe.addStateful(ProbeStep(
            name: "cmd-w-tab-confirm-cancel", timeout: 10,
            action: { [self] in
                guard let host = keyHost(), let window = host.window else {
                    probeFail("no host (⌘W confirm leg)")
                }
                newWindowForTab(nil)
                guard let tab = host.selectedTab, tab.allPanes().count == 1 else {
                    probeFail("⌘W leg: no fresh single-pane tab")
                }
                cmdWTab = tab
                setConfirmCloseTab(true)
                closePane(nil)  // the Shell ▸ Close Tab / ⌘W action
                guard let sheet = window.attachedSheet, let root = sheet.contentView else {
                    probeFail("⌘W on a single-pane tab did not open the confirmation sheet")
                }
                guard controllers.contains(where: { $0 === tab }) else {
                    probeFail("⌘W closed the tab before the sheet was answered")
                }
                func buttons(_ view: NSView) -> [NSButton] {
                    var out: [NSButton] = []
                    if let b = view as? NSButton { out.append(b) }
                    for sub in view.subviews { out += buttons(sub) }
                    return out
                }
                let all = buttons(root)
                guard let suppress = all.first(where: { $0.title == "Don't ask me again" }),
                      let cancel = all.first(where: { $0.title == "Cancel" }) else {
                    probeFail("⌘W sheet lacks its controls: \(all.map(\.title))")
                }
                // Check the box, then CANCEL: the setting must NOT change.
                suppress.state = .on
                cancel.performClick(nil)
            },
            condition: { [self] in keyHost()?.window?.attachedSheet == nil },
            assert: { [self] in
                guard let tab = cmdWTab, let host = keyHost() else {
                    throw ProbeFailure("⌘W leg lost its tab")
                }
                let alive = controllers.contains { $0 === tab }
                let settingKept = config.confirmCloseTab
                print("UIPROBE-CMDW-CONFIRM sheet=true cancelled=true tab_alive=\(alive) setting_kept_on=\(settingKept)")
                guard alive, settingKept else {
                    throw ProbeFailure("Cancel on the ⌘W sheet: tab alive=\(alive), setting still on=\(settingKept)")
                }
                // Setting off → ⌘W closes the tab outright, no sheet.
                setConfirmCloseTab(false)
                closePane(nil)
                guard host.window?.attachedSheet == nil else {
                    throw ProbeFailure("⌘W showed a sheet although confirm_close_tab is off")
                }
            }))
        probe.addStateful(ProbeStep(
            name: "cmd-w-tab-closes-when-off", timeout: 8,
            condition: { [self] in
                guard let tab = cmdWTab else { return false }
                return !controllers.contains { $0 === tab }
            },
            assert: { [self] in
                print("UIPROBE-CMDW-CONFIRM off=true closed=true focus_in_pane=\(keyHost()?.window?.firstResponder is PaneView)")
                guard keyHost()?.window?.firstResponder is PaneView else {
                    throw ProbeFailure("⌘W tab close left focus outside a pane")
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

// MARK: - Sheet-inspection helpers (council #1 legs)

/// First editable text field in a view tree (an NSAlert accessory field).
func probeFindField(_ view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    for sub in view.subviews {
        if let found = probeFindField(sub) { return found }
    }
    return nil
}

/// Button with an exact title in a view tree.
func probeFindButton(_ view: NSView, title: String) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    for sub in view.subviews {
        if let found = probeFindButton(sub, title: title) { return found }
    }
    return nil
}

/// Whether any (non-editable) text in the view tree contains `fragment` —
/// how the delete sheet's honest title is asserted without reaching into
/// NSAlert internals.
func probeFindTextInViews(_ view: NSView, containing fragment: String) -> Bool {
    if let field = view as? NSTextField, field.stringValue.contains(fragment) { return true }
    return view.subviews.contains { probeFindTextInViews($0, containing: fragment) }
}
