import AppKit
import MemtermCore

// Group G (FR-49..52): workspace runtime — switching, park/reopen, forget —
// plus the switcher menu and the titlebar chip plumbing. Switching and parking
// reuse the capture (flushSync) and restore (restoreWindows) pipelines that
// reboot-restore already exercises: parking a workspace and surviving a reboot
// are the same journal → restore path, which is the point of the feature.

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

    /// Switch = capture + close the current workspace's windows, then bring
    /// the target's back through the standard restore pipeline (ghost
    /// scrollback + consent-gated ⌘R offers come free). Switching to a parked
    /// workspace reopens (unparks) it.
    func switchToWorkspace(_ id: String) {
        guard let engine = memory else { return }
        let workspaces = engine.store.listWorkspaces()
        guard let target = workspaces.first(where: { $0.id == id }) else { return }
        guard id != activeWorkspaceId else {
            focusWindows(ofWorkspace: id)
            return
        }
        // Capture the outgoing workspace while its windows are still open.
        engine.flushSync()
        if target.isParked {
            engine.store.setWorkspaceParked(id, parked: false)  // reopen
        }
        let outgoing = controllers.filter { $0.workspaceId == activeWorkspaceId }
        isSwitchingWorkspaces = true
        // Materialize the target BEFORE closing the old windows so the window
        // count never hits zero (last-window-closed would terminate the app).
        if !controllers.contains(where: { $0.workspaceId == id }) {
            let restored = engine.store.loadState(workspaceId: id)
            if restored.isEmpty {
                openNewWindow(in: id)
            } else {
                restoreWindows(restored, workspaceId: id)
            }
        }
        for controller in outgoing { controller.close() }
        isSwitchingWorkspaces = false
        materializedWorkspaceIds.remove(activeWorkspaceId)
        materializedWorkspaceIds.insert(id)
        activeWorkspaceId = id
        engine.store.setMeta("active_workspace_id", id)
        focusWindows(ofWorkspace: id)
        rebuildWorkspaceMenu()
        engine.scheduleTopologySave()
    }

    /// Park = capture, close the windows, keep every journal row (FR-51).
    /// The last open workspace can't be parked — the app always has a window.
    func parkWorkspace(_ id: String) {
        guard let engine = memory else { return }
        let workspaces = engine.store.listWorkspaces()
        guard workspaces.contains(where: { $0.id == id }) else { return }
        let nonParked = workspaces.filter { !$0.isParked }
        if nonParked.count <= 1, nonParked.first?.id == id { return }
        if id == activeWorkspaceId {
            guard let fallback = nonParked.first(where: { $0.id != id }) else { return }
            switchToWorkspace(fallback.id)  // captures + closes this one for us
        } else if controllers.contains(where: { $0.workspaceId == id }) {
            engine.flushSync()
            isSwitchingWorkspaces = true
            for controller in controllers.filter({ $0.workspaceId == id }) { controller.close() }
            isSwitchingWorkspaces = false
            materializedWorkspaceIds.remove(id)
        }
        engine.store.setWorkspaceParked(id, parked: true)
        rebuildWorkspaceMenu()
    }

    /// Forget = purge journal rows AND scrollback files (FR-50/57). The last
    /// remaining workspace can't be forgotten.
    func forgetWorkspace(_ id: String) {
        guard let engine = memory else { return }
        let workspaces = engine.store.listWorkspaces()
        guard workspaces.count > 1, workspaces.contains(where: { $0.id == id }) else { return }
        if id == activeWorkspaceId {
            let others = workspaces.filter { $0.id != id }
            guard let fallback = others.first(where: { !$0.isParked }) ?? others.first else { return }
            switchToWorkspace(fallback.id)
        } else if controllers.contains(where: { $0.workspaceId == id }) {
            isSwitchingWorkspaces = true
            for controller in controllers.filter({ $0.workspaceId == id }) { controller.close() }
            isSwitchingWorkspaces = false
            materializedWorkspaceIds.remove(id)
        }
        engine.store.forgetWorkspace(id, scrollbackDir: engine.scrollbackDir)
        engine.store.barrier()
        materializedWorkspaceIds.remove(id)
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
        guard let store = memory?.store,
              let workspace = store.listWorkspaces().first(where: { $0.id == activeWorkspaceId })
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
        var byId: [String: WorkspaceRow] = [:]
        for workspace in store.listWorkspaces() { byId[workspace.id] = workspace }
        for controller in controllers {
            let workspace = byId[controller.workspaceId]
            controller.updateWorkspaceChip(
                name: workspace?.name ?? "Workspace",
                color: Self.nsColor(hex: workspace?.color ?? StateStore.defaultWorkspaceColor))
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

    private func promptForText(title: String, message: String, initial: String) -> String? {
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
