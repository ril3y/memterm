import AppKit
import MemtermCore

// Group G (FR-49..52, FR-59): workspace runtime — switching, park/reopen,
// forget — plus the switcher menu and the Settings-gear popup plumbing.
//
// FR-59 (founder decision 2026-08-31): SWITCHING IS NON-DESTRUCTIVE. Every
// pane's pty and process stays alive across a switch; switching back presents
// the same tab/pane objects with no restore pipeline, no "restored" divider,
// no respawn. The journal → resurrect pipeline runs ONLY when the processes
// are actually gone: app launch, and reopening a PARKED workspace. Park stays
// the explicit destructive-but-remembered gesture (capture + close windows +
// keep rows).
//
// CUSTOM-TAB-CHROME (stage 2): switching is a TAB-SET SWAP. In the common
// case the window the user is looking at never moves or hides — the visible
// host swaps the incoming workspace's tab group into its strip + content IN
// PLACE (same NSWindow, same frame — the founder's in-place presentation is
// the primitive now, not an adopted-frame special case), and the incoming
// group's former hidden host becomes the hidden holder of the outgoing group.
// Slots beyond the overlap show or hide whole (plain) hosts. Hidden hosts
// keep their tabs, order, and selection as first-class model state — capture
// reads them via captureGroups over hosts; the native-tab era's hiddenLayouts
// bookkeeping is gone (orderOut of a plain window dissolves nothing).

extension MemtermAppDelegate {

    /// The 6 preset chip colors (FR-50 recolor).
    static let workspaceColorPresets: [(name: String, hex: String)] = [
        ("Graphite", "#8e8e93"),
        ("Blue", "#0a84ff"),
        ("Green", "#28c840"),
        ("Yellow", "#febc2e"),
        ("Red", "#ff5f57"),
        ("Purple", "#bf5af2"),
    ]

    // MARK: - Core operations

    /// FR-59: switch = tab-set swap. The outgoing workspace is captured
    /// (scoped save); controllers stay in `controllers`, ptys and child
    /// processes untouched, capture keeps polling them. A target with LIVE
    /// tabs (hidden holders) is swapped into the visible hosts in place —
    /// same NSWindow the user is looking at, same frame, no window movement,
    /// ever. ONLY a target with no live tabs (parked, or never materialized
    /// this session) goes through the journal → resurrect pipeline (which
    /// builds fresh hosts; its primary adopts the key frame). Switching to a
    /// parked workspace reopens (unparks) it.
    func switchToWorkspace(_ id: String) {
        guard let engine = memory else { return }
        let workspaces = engine.store.listWorkspaces()
        guard let target = workspaces.first(where: { $0.id == id }) else { return }
        guard id != activeWorkspaceId else {
            focusWindows(ofWorkspace: id)
            return
        }
        // Capture the outgoing workspace while its tabs are still presented.
        engine.flushSync()
        if target.isParked {
            engine.store.setWorkspaceParked(id, parked: false)  // reopen
        }
        let outgoingId = activeWorkspaceId
        let fade = switchFadeEnabled
        isSwitchingWorkspaces = true
        // Slot order: the KEY host first — the in-place presentation swaps
        // the incoming primary group into the window the user is looking at.
        var outgoing = hosts.filter { $0.workspaceId == outgoingId }
        if let keyWindow = NSApp.keyWindow ?? NSApp.mainWindow
            ?? lastFocusedHost?.window,
           let keyIndex = outgoing.firstIndex(where: { $0.window === keyWindow }),
           keyIndex != 0 {
            outgoing.swapAt(0, keyIndex)
        }
        let incoming = hosts.filter { $0.workspaceId == id }
        if !incoming.isEmpty {
            swapTabSets(incoming: incoming, outgoing: outgoing, fade: fade)
        } else {
            // Resurrect path: no live tabs for this workspace exist — journal
            // rows become fresh tab models in fresh hosts; the primary host
            // adopts the outgoing key frame so the switch still presents in
            // place. The outgoing hosts hide whole (plain windows — nothing
            // dissolves; their tabs, order, and selection stay first-class).
            let adoptFrame = outgoing.first?.window?.frame
            fadeInPending = fade
            let restored = engine.store.loadState(workspaceId: id)
            if restored.isEmpty {
                let fresh = openNewWindow(in: id)
                if let adoptFrame { fresh.window?.setFrame(adoptFrame, display: true) }
                if fade { fresh.window?.alphaValue = 0 }
            } else {
                restoreWindows(restored, workspaceId: id, adoptingFrame: adoptFrame)
            }
            fadeInPending = false
            crossfadeInResurrected(incomingId: id, outgoingId: outgoingId,
                                   outgoing: outgoing, fade: fade)
        }
        isSwitchingWorkspaces = false
        // The outgoing workspace stays materialized: its tabs are live
        // (hidden), so its topology keeps being captured in scope.
        materializedWorkspaceIds.insert(id)
        activeWorkspaceId = id
        workspaceMRU.removeAll { $0 == outgoingId }
        workspaceMRU.insert(outgoingId, at: 0)
        // Founder UX: switching to a workspace sees its output — the chip's
        // activity mark (pulse/unseen ring) clears now.
        workspaceActivitySeen(id)
        engine.store.setMeta("active_workspace_id", id)
        rebuildWorkspaceMenu()
        engine.scheduleTopologySave()
    }

    /// The FR-59 swap: slot-matched over the two workspaces' ordered host
    /// lists. A slot occupied on both sides swaps IN PLACE — the visible host
    /// keeps its window and frame and swaps the incoming group into its
    /// strip + content (in-window crossfade under the snapshot overlay); the
    /// incoming group's former hidden host becomes the hidden holder of the
    /// outgoing group. An incoming group beyond the overlap shows its own
    /// host at its existing frame; an outgoing host beyond the overlap orders
    /// out whole. Frames are trivially stable: no window ever moves.
    private func swapTabSets(incoming: [WindowHostController],
                             outgoing: [WindowHostController], fade: Bool) {
        let pairs = min(incoming.count, outgoing.count)
        for slot in 0..<pairs {
            let visible = outgoing[slot]
            let holder = incoming[slot]
            let incomingTabs = holder.tabs
            let incomingSelected = holder.selectedTab
            let outgoingTabs = visible.tabs
            let outgoingSelected = visible.selectedTab
            if fade { visible.beginContentCrossfade() }
            visible.setTabs(incomingTabs, selecting: incomingSelected)
            holder.setTabs(outgoingTabs, selecting: outgoingSelected)
            holder.window?.orderOut(nil)  // the holder stays (or goes) hidden
        }
        // Incoming groups beyond the overlap: show their hosts as-is.
        if incoming.count > outgoing.count {
            for host in incoming[outgoing.count...] {
                guard let window = host.window else { continue }
                if fade { window.alphaValue = 0 }
                window.orderFront(nil)
            }
        }
        // Outgoing hosts beyond the overlap: hide whole, after the fade.
        let extraOutgoing = outgoing.count > incoming.count
            ? Array(outgoing[incoming.count...]) : []
        if fade {
            let shownExtras = incoming.count > outgoing.count
                ? Array(incoming[outgoing.count...]) : []
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for host in shownExtras { host.window?.animator().alphaValue = 1 }
                for host in extraOutgoing { host.window?.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                guard let self else { return }
                for host in extraOutgoing {
                    // Re-switch during the fade: hide only what is still not
                    // the active workspace's (the swap may have re-homed it).
                    if host.workspaceId != self.activeWorkspaceId {
                        host.window?.orderOut(nil)
                    }
                    host.window?.alphaValue = 1
                }
            })
        } else {
            for host in extraOutgoing { host.window?.orderOut(nil) }
        }
        (outgoing.first ?? incoming.first)?.focusWindow()
    }

    /// Resurrect-path presentation: the freshly built hosts rise from alpha 0
    /// (fadeInPending) over the still-visible outgoing windows, which hide
    /// after the fade — alphas restored while hidden. orderOut fires no
    /// delegate events, so nothing here needs the isSwitchingWorkspaces guard
    /// once the fade ends.
    private func crossfadeInResurrected(incomingId: String, outgoingId: String,
                                        outgoing: [WindowHostController], fade: Bool) {
        guard fade else {
            for host in outgoing { host.window?.orderOut(nil) }
            return
        }
        let incomingWindows = hosts.filter { $0.workspaceId == incomingId }
            .compactMap(\.window)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            incomingWindows.forEach { $0.animator().alphaValue = 1 }
            outgoing.forEach { $0.window?.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self else { return }
            for host in outgoing {
                // Re-switch during the fade: leave the now-active alone.
                if host.workspaceId != self.activeWorkspaceId {
                    host.window?.orderOut(nil)
                }
                host.window?.alphaValue = 1
            }
        })
    }

    /// Founder (stage 2): closing the LAST tab of a non-Default workspace
    /// removes the now-empty workspace outright — its rows, scrollback, and
    /// chip all go; Default persists forever. Called from the tab teardown
    /// path for USER closes only — quit, park, forget, and a shell dying on
    /// its own never auto-remove (FR-56: memory follows intent, and only a
    /// gesture is intent). The last remaining workspace also persists (the
    /// app always has one).
    func workspaceEmptiedByUserClose(_ workspaceId: String) {
        guard workspaceId != StateStore.defaultWorkspaceId,
              let engine = memory,
              !controllers.contains(where: { $0.workspaceId == workspaceId }),
              engine.store.listWorkspaces().contains(where: { $0.id == workspaceId }),
              engine.store.listWorkspaces().count > 1 else { return }
        engine.store.forgetWorkspace(workspaceId, scrollbackDir: engine.scrollbackDir,
                                     historyDir: engine.historyDir)
        materializedWorkspaceIds.remove(workspaceId)
        workspaceMRU.removeAll { $0 == workspaceId }
        workspaceActivityForgotten(workspaceId)
        // activeWorkspaceId may still name the removed workspace for a
        // moment: the deferred MRU surfacing (activeWorkspaceWindowClosed)
        // switches away, and the launch path's active-workspace fallback
        // covers a quit in between.
        rebuildWorkspaceMenu()
    }

    /// Park = capture, close the windows, keep every journal row (FR-51).
    /// FR-59: park stays destructive-but-remembered — parking a workspace with
    /// live processes may terminate them; that is what the explicit gesture
    /// means. (Switching away first only HIDES, so parking the active
    /// workspace must close its now-hidden windows itself.) The last open
    /// workspace can't be parked — the app always has a window.
    func parkWorkspace(_ id: String) {
        guard let engine = memory else { return }
        let workspaces = engine.store.listWorkspaces()
        guard workspaces.contains(where: { $0.id == id }) else { return }
        let nonParked = workspaces.filter { !$0.isParked }
        if nonParked.count <= 1, nonParked.first?.id == id { return }
        if id == activeWorkspaceId {
            guard let fallback = nonParked.first(where: { $0.id != id }) else { return }
            switchToWorkspace(fallback.id)  // hides this one; capture ran in the switch
        }
        if controllers.contains(where: { $0.workspaceId == id }) {
            engine.flushSync()  // capture the (possibly hidden) windows before closing
            isSwitchingWorkspaces = true
            for controller in controllers.filter({ $0.workspaceId == id }) { controller.close() }
            isSwitchingWorkspaces = false
            materializedWorkspaceIds.remove(id)
        }
        engine.store.setWorkspaceParked(id, parked: true)
        rebuildWorkspaceMenu()
    }

    /// Forget = purge journal rows AND scrollback files (FR-50/57). The last
    /// remaining workspace can't be forgotten. Like park, this closes the
    /// workspace's (possibly hidden) windows itself — switching only hides.
    func forgetWorkspace(_ id: String) {
        guard let engine = memory else { return }
        let workspaces = engine.store.listWorkspaces()
        guard workspaces.count > 1, workspaces.contains(where: { $0.id == id }) else { return }
        if id == activeWorkspaceId {
            let others = workspaces.filter { $0.id != id }
            guard let fallback = others.first(where: { !$0.isParked }) ?? others.first else { return }
            switchToWorkspace(fallback.id)
        }
        if controllers.contains(where: { $0.workspaceId == id }) {
            isSwitchingWorkspaces = true
            for controller in controllers.filter({ $0.workspaceId == id }) { controller.close() }
            isSwitchingWorkspaces = false
        }
        engine.store.forgetWorkspace(id, scrollbackDir: engine.scrollbackDir,
                                     historyDir: engine.historyDir)
        engine.store.barrier()
        materializedWorkspaceIds.remove(id)
        workspaceActivityForgotten(id)
        rebuildWorkspaceMenu()
    }

    @discardableResult
    func createWorkspace(named name: String) -> String? {
        guard let store = memory?.store else { return nil }
        let presets = Self.workspaceColorPresets
        let color = presets[store.listWorkspaces().count % presets.count].hex
        let id = store.createWorkspace(name: name, color: color)
        rebuildWorkspaceMenu()
        return id
    }

    func focusWindows(ofWorkspace id: String) {
        hosts.first { $0.workspaceId == id }?.focusWindow()
    }

    /// FR-58: reassigns a live tab to another workspace, then FOLLOWS the tab
    /// (switches to the target) so the FR-59 invariant — exactly the active
    /// workspace's windows are visible — holds. The next scoped topology save
    /// rewrites both workspaces' rows (old without this tab, new with it; both
    /// are in captureScope via materializedWorkspaceIds / the controllers
    /// list). Moving a tab into a parked workspace reopens it.
    func moveTab(_ controller: TerminalWindowController, toWorkspace id: String) {
        guard controller.workspaceId != id, let engine = memory,
              let target = engine.store.listWorkspaces().first(where: { $0.id == id })
        else { return }
        if target.isParked { engine.store.setWorkspaceParked(id, parked: false) }
        // The scoped topology save that follows rewrites ALL of the target
        // workspace's rows from live windows — so a target with journal rows
        // but no windows (parked this session) must be materialized through
        // the standard restore pipeline FIRST, or the save would erase its
        // stored tabs, a forget the user never asked for (FR-51: park keeps
        // every journal row; FR-56: only a user gesture forgets). A target
        // with HIDDEN live windows needs nothing: its windows are live and in
        // capture scope already (FR-59).
        if !controllers.contains(where: { $0.workspaceId == id }) {
            let stored = engine.store.loadState(workspaceId: id)
            if !stored.isEmpty {
                restoreWindows(stored, workspaceId: id)
            }
        }
        // Re-home the TabController: detach from its current host (an emptied
        // host closes its window — no teardown, the tab just moved) and join
        // the target workspace's host, or a fresh one.
        controller.host?.detach(controller)
        controller.setWorkspace(id)
        if let target = hosts.first(where: { $0.workspaceId == id }) {
            target.attach(controller, select: true)
        } else {
            let fresh = makeHost(frame: nil)
            fresh.attach(controller, select: true)
            fresh.showWindow(nil)
        }
        materializedWorkspaceIds.insert(id)
        rebuildWorkspaceMenu()
        engine.scheduleTopologySave()
        // Follow the tab: the target becomes the visible workspace. (If the
        // old workspace lost its last tab it simply hides with zero windows.)
        if id != activeWorkspaceId {
            switchToWorkspace(id)
        } else {
            controller.host?.focusWindow()
        }
    }

    // MARK: - Menu actions

    @objc func switchWorkspaceItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switchToWorkspace(id)
    }

    @objc func newWorkspaceAction(_ sender: Any?) {
        let count = memory?.store.listWorkspaces().count ?? 0
        guard let name = promptForText(title: "New Workspace",
                                       message: "Name the new workspace:",
                                       initial: "Workspace \(count + 1)") else { return }
        if let id = createWorkspace(named: name) {
            switchToWorkspace(id)
        }
    }

    @objc func renameWorkspaceAction(_ sender: Any?) {
        guard let store = memory?.store,
              let workspace = store.listWorkspaces().first(where: { $0.id == activeWorkspaceId })
        else { return }
        guard let name = promptForText(title: "Rename Workspace",
                                       message: "New name for “\(workspace.name)”:",
                                       initial: workspace.name) else { return }
        store.renameWorkspace(workspace.id, name: name)
        rebuildWorkspaceMenu()
    }

    @objc func recolorWorkspaceItem(_ sender: NSMenuItem) {
        guard let hex = sender.representedObject as? String else { return }
        memory?.store.recolorWorkspace(activeWorkspaceId, color: hex)
        rebuildWorkspaceMenu()
    }

    @objc func parkActiveWorkspaceAction(_ sender: Any?) {
        parkWorkspace(activeWorkspaceId)
    }

    /// FR-50: deleting offers "park" vs "forget".
    @objc func deleteWorkspaceAction(_ sender: Any?) {
        confirmDeleteWorkspace(activeWorkspaceId)
    }

    func confirmDeleteWorkspace(_ id: String) {
        guard let store = memory?.store,
              let workspace = store.listWorkspaces().first(where: { $0.id == id })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Delete workspace “\(workspace.name)”?"
        alert.informativeText = """
            Park keeps its tabs, layout, and scrollback in the journal so it can \
            be reopened later. Forget removes them permanently, including the \
            scrollback files on disk.
            """
        alert.addButton(withTitle: "Park")
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: parkWorkspace(workspace.id)
        case .alertSecondButtonReturn: forgetWorkspace(workspace.id)
        default: break
        }
    }

    @objc func nextWorkspace(_ sender: Any?) { cycleWorkspace(by: 1) }
    @objc func previousWorkspace(_ sender: Any?) { cycleWorkspace(by: -1) }

    /// ⌃⌘←/→ cycle among the OPEN (non-parked) workspaces; parked ones are
    /// reopened deliberately from the switcher, never by cycling into them.
    private func cycleWorkspace(by offset: Int) {
        guard let store = memory?.store else { return }
        let open = store.listWorkspaces().filter { !$0.isParked }
        guard open.count > 1,
              let current = open.firstIndex(where: { $0.id == activeWorkspaceId }) else { return }
        let next = (current + offset + open.count) % open.count
        switchToWorkspace(open[next].id)
    }

    // MARK: - Tabs (FR-52: ⌘1–⌘8 tab N, ⌘9 last tab)

    @objc func selectTab(_ sender: NSMenuItem) {
        guard let host = keyHost() else { return }
        let index = sender.tag == 9 ? host.tabs.count - 1 : sender.tag - 1
        host.selectTab(at: index)
    }

    // MARK: - Switcher menu

    /// Rebuilds the Shell ▸ Workspace submenu in place (its ⌃⌘n / ⌃⌘arrow key
    /// equivalents must exist in the menu bar to fire) and refreshes chips.
    func rebuildWorkspaceMenu() {
        populateWorkspaceMenu(workspaceMenu)
        refreshWorkspaceChips()
    }

    /// A fresh copy for the Settings gear's right-click popup (an NSMenu
    /// can't be shown in two places at once).
    func makeWorkspacePopUpMenu() -> NSMenu {
        let menu = NSMenu(title: "Workspace")
        populateWorkspaceMenu(menu)
        return menu
    }

    /// FR-58: the Workspace submenu of the pane context menu — the full
    /// switcher (switch-to items, New/Rename/Color, Park, Delete…) plus the
    /// tab-scoped items: "New Workspace from Tab…" and "Move Tab to
    /// Workspace ▸". Creating a workspace is reachable by right-click alone.
    func makeWorkspaceContextMenu(for controller: TerminalWindowController) -> NSMenu {
        let menu = NSMenu(title: "Workspace")
        populateWorkspaceMenu(menu)
        menu.addItem(.separator())

        let newFromTab = NSMenuItem(title: "New Workspace from Tab…",
                                    action: #selector(newWorkspaceFromTabItem(_:)),
                                    keyEquivalent: "")
        newFromTab.target = self
        newFromTab.representedObject = MoveTabRequest(controller: controller, workspaceId: nil)
        menu.addItem(newFromTab)

        let moveItem = NSMenuItem(title: "Move Tab to Workspace", action: nil, keyEquivalent: "")
        moveItem.submenu = makeMoveTabSubmenu(for: controller)
        menu.addItem(moveItem)
        return menu
    }

    /// "Move Tab to Workspace ▸" submenu — shared between the pane context
    /// menu (FR-58) and the tab-strip right-click menu (founder UX stage).
    func makeMoveTabSubmenu(for controller: TerminalWindowController) -> NSMenu {
        let moveMenu = NSMenu(title: "Move Tab to Workspace")
        if let store = memory?.store {
            for workspace in store.listWorkspaces() {
                let isCurrent = workspace.id == controller.workspaceId
                let item = NSMenuItem(
                    title: workspace.isParked ? "\(workspace.name) — parked" : workspace.name,
                    // The tab's own workspace is shown checked and inert.
                    action: isCurrent ? nil : #selector(moveTabToWorkspaceItem(_:)),
                    keyEquivalent: "")
                item.target = isCurrent ? nil : self
                item.image = Self.chipImage(hex: workspace.color)
                item.state = isCurrent ? .on : .off
                item.representedObject = MoveTabRequest(controller: controller,
                                                        workspaceId: workspace.id)
                moveMenu.addItem(item)
            }
        }
        return moveMenu
    }

    // MARK: - Workspace-bar chip menu (founder UX: right-click a chip)

    /// The per-workspace menu the bar chips pop on right-click: Rename
    /// (inline, in the bar), Color ▸, Park / Reopen, Delete…. Unlike the
    /// switcher menu these target the CLICKED workspace, not the active one.
    func makeWorkspaceChipMenu(for id: String) -> NSMenu? {
        guard let store = memory?.store,
              let workspace = store.listWorkspaces().first(where: { $0.id == id })
        else { return nil }
        let menu = NSMenu(title: workspace.name)

        func add(_ title: String, _ action: Selector, represented: Any) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = represented
            menu.addItem(item)
        }
        add("Rename", #selector(chipRenameWorkspaceItem(_:)), represented: id)

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "Color")
        for preset in Self.workspaceColorPresets {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(recolorWorkspaceTargetItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = WorkspaceColorRequest(workspaceId: id, color: preset.hex)
            item.image = Self.chipImage(hex: preset.hex)
            item.state = preset.hex == workspace.color ? .on : .off
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        menu.addItem(.separator())

        if workspace.isParked {
            add("Reopen", #selector(reopenWorkspaceItem(_:)), represented: id)
        } else {
            let canPark = store.listWorkspaces().filter { !$0.isParked }.count > 1
            let item = NSMenuItem(title: "Park", action: canPark
                                  ? #selector(parkWorkspaceItem(_:)) : nil, keyEquivalent: "")
            item.target = canPark ? self : nil
            item.representedObject = id
            menu.addItem(item)
        }
        let canDelete = store.listWorkspaces().count > 1
        let delete = NSMenuItem(title: "Delete…", action: canDelete
                                ? #selector(deleteWorkspaceItem(_:)) : nil, keyEquivalent: "")
        delete.target = canDelete ? self : nil
        delete.representedObject = id
        menu.addItem(delete)
        return menu
    }

    @objc func chipRenameWorkspaceItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        keyHost()?.beginWorkspaceRename(id)
    }

    @objc func recolorWorkspaceTargetItem(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? WorkspaceColorRequest else { return }
        memory?.store.recolorWorkspace(request.workspaceId, color: request.color)
        rebuildWorkspaceMenu()
    }

    @objc func parkWorkspaceItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        parkWorkspace(id)
    }

    @objc func reopenWorkspaceItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        switchToWorkspace(id)  // switching to a parked workspace reopens it
    }

    @objc func deleteWorkspaceItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        confirmDeleteWorkspace(id)
    }

    @objc func newWorkspaceFromTabItem(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? MoveTabRequest,
              let controller = request.controller else { return }
        let count = memory?.store.listWorkspaces().count ?? 0
        guard let name = promptForText(title: "New Workspace from Tab",
                                       message: "Name the new workspace:",
                                       initial: "Workspace \(count + 1)"),
              let id = createWorkspace(named: name) else { return }
        moveTab(controller, toWorkspace: id)
    }

    @objc func moveTabToWorkspaceItem(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? MoveTabRequest,
              let controller = request.controller,
              let workspaceId = request.workspaceId else { return }
        moveTab(controller, toWorkspace: workspaceId)
    }

    private func populateWorkspaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let store = memory?.store else { return }
        let list = store.listWorkspaces()

        for (i, workspace) in list.enumerated() {
            let item = NSMenuItem(title: workspace.isParked ? "\(workspace.name) — parked"
                                                            : workspace.name,
                                  action: #selector(switchWorkspaceItem(_:)),
                                  keyEquivalent: i < 9 ? String(i + 1) : "")
            item.keyEquivalentModifierMask = [.control, .command]  // ⌃⌘n (FR-52)
            item.target = self
            item.representedObject = workspace.id
            item.state = workspace.id == activeWorkspaceId ? .on : .off
            item.image = Self.chipImage(hex: workspace.color)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let prev = NSMenuItem(title: "Previous Workspace",
                              action: #selector(previousWorkspace(_:)), keyEquivalent: left)
        prev.keyEquivalentModifierMask = [.control, .command]
        prev.target = self
        menu.addItem(prev)
        let next = NSMenuItem(title: "Next Workspace",
                              action: #selector(nextWorkspace(_:)), keyEquivalent: right)
        next.keyEquivalentModifierMask = [.control, .command]
        next.target = self
        menu.addItem(next)
        menu.addItem(.separator())

        func plain(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        plain("New Workspace…", #selector(newWorkspaceAction(_:)))
        plain("Rename Workspace…", #selector(renameWorkspaceAction(_:)))

        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorMenu = NSMenu(title: "Color")
        let activeColor = list.first { $0.id == activeWorkspaceId }?.color
        for preset in Self.workspaceColorPresets {
            let item = NSMenuItem(title: preset.name,
                                  action: #selector(recolorWorkspaceItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.hex
            item.image = Self.chipImage(hex: preset.hex)
            item.state = preset.hex == activeColor ? .on : .off
            colorMenu.addItem(item)
        }
        colorItem.submenu = colorMenu
        menu.addItem(colorItem)
        menu.addItem(.separator())

        plain("Park Workspace", #selector(parkActiveWorkspaceAction(_:)))
        plain("Delete Workspace…", #selector(deleteWorkspaceAction(_:)))
    }

    // MARK: - Chips

    func refreshWorkspaceChips() {
        guard let store = memory?.store else { return }
        let list = store.listWorkspaces()
        let activity = workspaceActivityStates()
        var byId: [String: WorkspaceRow] = [:]
        for workspace in list { byId[workspace.id] = workspace }
        for host in hosts {
            let workspace = host.workspaceId.flatMap { byId[$0] }
            host.updateGearTooltip(workspaceName: workspace?.name ?? "Workspace")
            host.updateWorkspaceBar(workspaces: list, activeId: activeWorkspaceId,
                                    activity: activity)
        }
    }

    static func nsColor(hex: String) -> NSColor {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = Int(h, radix: 16) else { return .systemGray }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    static func chipImage(hex: String) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            Self.nsColor(hex: hex).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Name prompt (FR-50: NSAlert with accessory text field)

    func promptForText(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// representedObject payload for the chip-menu color items: which workspace,
/// which preset.
final class WorkspaceColorRequest: NSObject {
    let workspaceId: String
    let color: String

    init(workspaceId: String, color: String) {
        self.workspaceId = workspaceId
        self.color = color
    }
}

/// representedObject payload for the tab-scoped workspace menu items: which
/// tab, and (for move items) which destination workspace. The controller is
/// weak — a menu can outlive a closing tab.
final class MoveTabRequest: NSObject {
    weak var controller: TerminalWindowController?
    let workspaceId: String?

    init(controller: TerminalWindowController, workspaceId: String?) {
        self.controller = controller
        self.workspaceId = workspaceId
    }
}

// MARK: - Menu validation

extension MemtermAppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // feature/serial: the hex lens reflects and requires a serial pane.
        if item.action == #selector(toggleHexView(_:)) {
            let serial = keyController()?.currentPane() as? SerialPaneView
            item.state = serial?.hexMode == true ? .on : .off
            return serial != nil
        }
        guard let store = memory?.store else { return true }
        switch item.action {
        case #selector(parkActiveWorkspaceAction(_:)):
            // The last open workspace stays open.
            return store.listWorkspaces().filter { !$0.isParked }.count > 1
        case #selector(deleteWorkspaceAction(_:)):
            return store.listWorkspaces().count > 1
        case #selector(nextWorkspace(_:)), #selector(previousWorkspace(_:)):
            return store.listWorkspaces().filter { !$0.isParked }.count > 1
        default:
            return true
        }
    }
}
