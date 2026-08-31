import AppKit
import MemtermCore

// Group G (FR-49..52, FR-59): workspace runtime — switching, park/reopen,
// forget — plus the switcher menu and the titlebar chip plumbing.
//
// FR-59 (founder decision 2026-08-31): SWITCHING IS NON-DESTRUCTIVE. A switch
// hides the outgoing workspace's windows (orderOut) and keeps every pane's pty
// and process alive; switching back shows the same NSWindow objects at their
// existing frames — no restore pipeline, no "restored" divider, no respawn.
// The journal → resurrect pipeline runs ONLY when the processes are actually
// gone: app launch, and reopening a PARKED workspace. Park stays the explicit
// destructive-but-remembered gesture (capture + close windows + keep rows).
//
// EMPIRICAL FACT (probe, macOS 26.2): orderOut() dissolves native tab groups —
// each hidden window lands in its own single-window group (frames survive).
// So hiding records each group's tab order + selected tab (hiddenLayouts on
// the delegate), showing regroups via addTabbedWindow, and topology capture of
// hidden workspaces uses the recorded layout (captureGroups), never the
// dissolved live tabGroups.

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

    /// FR-59: switch = hide/show. The outgoing workspace is captured (scoped
    /// save) and its windows ordered out — controllers stay in `controllers`,
    /// ptys and child processes untouched, capture keeps polling them. If the
    /// target has hidden live windows they are shown again (same NSWindow
    /// objects, same frames, regrouped from the recorded layout). ONLY a
    /// target with no live windows (parked, or never materialized this
    /// session) goes through the journal → resurrect pipeline. Switching to a
    /// parked workspace reopens (unparks) it.
    func switchToWorkspace(_ id: String) {
        guard let engine = memory else { return }
        let workspaces = engine.store.listWorkspaces()
        guard let target = workspaces.first(where: { $0.id == id }) else { return }
        guard id != activeWorkspaceId else {
            focusWindows(ofWorkspace: id)
            return
        }
        // Capture the outgoing workspace while its windows are still visible.
        engine.flushSync()
        if target.isParked {
            engine.store.setWorkspaceParked(id, parked: false)  // reopen
        }
        let outgoingId = activeWorkspaceId
        // Founder (2026-08-31): switching presents IN PLACE — the incoming
        // workspace's primary tab group takes over the frame the user is
        // looking at, Safari-tab-groups style. No window movement, ever.
        let adoptFrame = (NSApp.keyWindow
            ?? controllers.first { $0.workspaceId == outgoingId }?.window)?.frame
        let fade = switchFadeEnabled
        isSwitchingWorkspaces = true
        fadeInPending = fade
        // Bring the target up FIRST, hide the outgoing after — the app never
        // passes through a windowless moment.
        if !showHiddenWindows(of: id, adoptingFrame: adoptFrame) {
            // Resurrect path: no live windows for this workspace exist.
            let restored = engine.store.loadState(workspaceId: id)
            if restored.isEmpty {
                let fresh = openNewWindow(in: id)
                if let adoptFrame { fresh.window?.setFrame(adoptFrame, display: true) }
                if fade { fresh.window?.alphaValue = 0 }
            } else {
                restoreWindows(restored, workspaceId: id, adoptingFrame: adoptFrame)
            }
        }
        fadeInPending = false
        if fade {
            // Crossfade (founder: the hard cut read un-macOS): incoming windows
            // rise from alpha 0 over the still-visible outgoing ones; the
            // outgoing are ordered out only after the fade, alphas restored
            // while hidden. orderOut fires no delegate events, so nothing
            // here needs the isSwitchingWorkspaces guard once the fade ends.
            let incoming = controllers.filter { $0.workspaceId == id }.compactMap(\.window)
            let outgoing = controllers.filter { $0.workspaceId == outgoingId }.compactMap(\.window)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                incoming.forEach { $0.animator().alphaValue = 1 }
                outgoing.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { [weak self] in
                guard let self else { return }
                // Re-switch during the fade: leave whatever is now active alone.
                if self.activeWorkspaceId != outgoingId {
                    self.hideWindows(of: outgoingId)
                }
                for controller in self.controllers where controller.workspaceId == outgoingId {
                    controller.window?.alphaValue = 1
                }
            })
        } else {
            hideWindows(of: outgoingId)
        }
        isSwitchingWorkspaces = false
        // The outgoing workspace stays materialized: its windows are live
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

    /// Orders out every window of `workspaceId` after recording its tab-group
    /// layout (order + selection), because orderOut dissolves native tab
    /// groups (see the header note). Nothing is closed; nothing is forgotten.
    func hideWindows(of workspaceId: String) {
        let members = controllers.filter { $0.workspaceId == workspaceId }
        guard !members.isEmpty else { return }
        let keyWindow = NSApp.keyWindow
        var layout = HiddenWorkspaceLayout(
            groups: [], keyTabId: members.first { $0.window === keyWindow }?.tabId)
        for group in MemoryEngine.groupedControllers(members) {
            // Strip order from the live tab group while it still exists.
            let ordered: [TerminalWindowController]
            if let tabWindows = group.first?.window?.tabGroup?.windows, tabWindows.count > 1 {
                ordered = tabWindows.compactMap { w in group.first { $0.window === w } }
            } else {
                ordered = group
            }
            let selected = group.first { $0.window?.tabGroup?.selectedWindow === $0.window }
            layout.groups.append(HiddenWorkspaceLayout.Group(
                tabIds: ordered.map(\.tabId),
                selectedTabId: (selected ?? ordered.first)?.tabId))
            for controller in ordered { controller.window?.orderOut(nil) }
        }
        hiddenLayouts[workspaceId] = layout
    }

    /// Shows the hidden live windows of `workspaceId`, regrouping tabs from
    /// the recorded layout and restoring the selected tab. Returns false when
    /// the workspace has no live windows (caller falls back to resurrect).
    /// Windows keep their frames — nothing here centers, cascades, or moves.
    @discardableResult
    func showHiddenWindows(of workspaceId: String, adoptingFrame: NSRect? = nil) -> Bool {
        let members = controllers.filter { $0.workspaceId == workspaceId }
        guard !members.isEmpty else { return false }
        if fadeInPending {
            for member in members { member.window?.alphaValue = 0 }
        }
        let layout = hiddenLayouts.removeValue(forKey: workspaceId)
        var byTab: [String: TerminalWindowController] = [:]
        for member in members { byTab[member.tabId] = member }
        // In-place switch: the primary group (the one holding the workspace's
        // last key tab, else the first) adopts the outgoing window's frame;
        // secondary windows keep their own frames.
        let groups = layout?.groups ?? []
        let primaryIndex = groups.firstIndex {
            $0.tabIds.contains(layout?.keyTabId ?? "")
        } ?? (groups.isEmpty ? nil : 0)
        var shown = Set<ObjectIdentifier>()
        var focusTarget: TerminalWindowController?
        for (index, group) in groups.enumerated() {
            let live = group.tabIds.compactMap { byTab[$0] }
            guard let host = live.first, let hostWindow = host.window else { continue }
            if index == primaryIndex, let adoptingFrame {
                hostWindow.setFrame(adoptingFrame, display: false)
            }
            hostWindow.orderFront(nil)
            shown.insert(ObjectIdentifier(host))
            var anchor = hostWindow
            for controller in live.dropFirst() {
                guard let window = controller.window else { continue }
                if hostWindow.tabGroup?.windows.contains(window) != true {
                    // orderOut dissolved the group: re-tab in strip order.
                    anchor.addTabbedWindow(window, ordered: .above)
                }
                window.orderFront(nil)
                anchor = window
                shown.insert(ObjectIdentifier(controller))
            }
            let selected = group.selectedTabId.flatMap { byTab[$0] } ?? host
            selected.window?.makeKeyAndOrderFront(nil)
            if focusTarget == nil || group.tabIds.contains(layout?.keyTabId ?? "") {
                focusTarget = selected
            }
        }
        // Members the layout doesn't cover (a tab moved into this hidden
        // workspace, or a layout lost to a close): just bring them forward.
        for member in members where !shown.contains(ObjectIdentifier(member)) {
            member.window?.orderFront(nil)
            if focusTarget == nil { focusTarget = member }
        }
        focusTarget?.window?.makeKeyAndOrderFront(nil)
        return true
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
        hiddenLayouts.removeValue(forKey: id)
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
        hiddenLayouts.removeValue(forKey: id)
        engine.store.forgetWorkspace(id, scrollbackDir: engine.scrollbackDir)
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
        controllers.first { $0.workspaceId == id }?.window?.makeKeyAndOrderFront(nil)
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
        if let window = controller.window, let group = window.tabGroup,
           group.windows.count > 1 {
            group.removeWindow(window)
        }
        controller.setWorkspace(id)
        // Join the target's tab group when one exists (hidden hosts count:
        // the switch below will show the whole group, moved tab included).
        if let host = controllers.first(where: { $0 !== controller && $0.workspaceId == id })?.window,
           let moved = controller.window {
            host.addTabbedWindow(moved, ordered: .above)
        }
        // A moved tab joining a hidden group must be part of that group's
        // recorded layout, or showHiddenWindows would strand it ungrouped.
        // Simplest correct fix: drop the stale layout; the show path's
        // fallback loop brings every member forward and live grouping (just
        // re-established by addTabbedWindow) is intact again.
        hiddenLayouts.removeValue(forKey: id)
        materializedWorkspaceIds.insert(id)
        rebuildWorkspaceMenu()
        engine.scheduleTopologySave()
        // Follow the tab: the target becomes the visible workspace. (If the
        // old workspace lost its last tab it simply hides with zero windows.)
        if id != activeWorkspaceId {
            switchToWorkspace(id)
        } else {
            controller.window?.makeKeyAndOrderFront(nil)
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
        guard let window = keyController()?.window else { return }
        let tabWindows = window.tabGroup?.windows ?? [window]
        let index = sender.tag == 9 ? tabWindows.count - 1 : sender.tag - 1
        guard tabWindows.indices.contains(index) else { return }
        tabWindows[index].makeKeyAndOrderFront(nil)
    }

    // MARK: - Switcher menu

    /// Rebuilds the Shell ▸ Workspace submenu in place (its ⌃⌘n / ⌃⌘arrow key
    /// equivalents must exist in the menu bar to fire) and refreshes chips.
    func rebuildWorkspaceMenu() {
        populateWorkspaceMenu(workspaceMenu)
        refreshWorkspaceChips()
    }

    /// A fresh copy for the titlebar chip's popup (an NSMenu can't be shown
    /// in two places at once).
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
        keyController()?.beginWorkspaceRename(id)
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
        for controller in controllers {
            let workspace = byId[controller.workspaceId]
            controller.updateWorkspaceChip(
                name: workspace?.name ?? "Workspace",
                color: Self.nsColor(hex: workspace?.color ?? StateStore.defaultWorkspaceColor))
            controller.updateWorkspaceBar(workspaces: list, activeId: activeWorkspaceId,
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
