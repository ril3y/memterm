import AppKit

// Programmatic main menu. Without this, ⌘C/⌘V/⌘Q reach nothing — SwiftTerm's
// copy:/paste:/selectAll: only fire via the responder chain from menu items.

func buildMainMenu(for app: MemtermAppDelegate) -> NSMenu {
    // We provide the Enter Full Screen item OURSELVES (council #6) — turn
    // off AppKit's automatic insertion, which on this macOS stacks its own
    // copies next to ours (live-verified: three identical items).
    UserDefaults.standard.register(defaults: ["NSFullScreenMenuItemEverywhere": false])
    let main = NSMenu()

    func add(_ title: String, to menu: NSMenu, _ action: Selector?, _ key: String,
             modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
    }

    func submenu(_ title: String) -> NSMenu {
        let item = main.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        main.setSubmenu(menu, for: item)
        return menu
    }

    // App
    let appMenu = submenu("memterm")
    add("About memterm", to: appMenu,
        #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", modifiers: [])
    add("Check for Updates…", to: appMenu,
        #selector(MemtermAppDelegate.checkForUpdates(_:)), "", modifiers: [])
    appMenu.addItem(.separator())
    add("Settings…", to: appMenu, #selector(MemtermAppDelegate.openPreferences(_:)), ",",
        target: app)
    add("Edit Config File…", to: appMenu, #selector(MemtermAppDelegate.openConfigFile(_:)), "",
        modifiers: [], target: app)
    appMenu.addItem(.separator())
    // FR-45/57: the global wipe, confirmation-gated in the action.
    add("Forget Everything…", to: appMenu,
        #selector(MemtermAppDelegate.forgetEverythingAction(_:)), "", modifiers: [],
        target: app)
    appMenu.addItem(.separator())
    // Council #6 menu hygiene: the standard Services submenu (every native
    // app has one; text selected in a pane feeds system services).
    let servicesItem = appMenu.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
    let servicesMenu = NSMenu(title: "Services")
    appMenu.setSubmenu(servicesMenu, for: servicesItem)
    NSApp.servicesMenu = servicesMenu
    appMenu.addItem(.separator())
    add("Hide memterm", to: appMenu, #selector(NSApplication.hide(_:)), "h")
    add("Hide Others", to: appMenu, #selector(NSApplication.hideOtherApplications(_:)), "h",
        modifiers: [.command, .option])
    add("Show All", to: appMenu, #selector(NSApplication.unhideAllApplications(_:)), "",
        modifiers: [])
    appMenu.addItem(.separator())
    add("Quit memterm", to: appMenu, #selector(NSApplication.terminate(_:)), "q")

    // Shell
    let shellMenu = submenu("Shell")
    add("New Window", to: shellMenu, #selector(MemtermAppDelegate.newWindow(_:)), "n",
        target: app)
    // Custom chrome: the strip's "+" shares this exact action.
    add("New Tab", to: shellMenu, #selector(MemtermAppDelegate.newWindowForTab(_:)), "t",
        target: app)
    // feature/serial: ⌘⇧K verified unclaimed (⌘K = View ▸ Clear).
    add("New Serial Connection…", to: shellMenu,
        #selector(MemtermAppDelegate.newSerialConnection(_:)), "k",
        modifiers: [.command, .shift], target: app)
    shellMenu.addItem(.separator())
    add("Split Right", to: shellMenu, #selector(MemtermAppDelegate.splitRight(_:)), "d",
        target: app)
    add("Split Down", to: shellMenu, #selector(MemtermAppDelegate.splitDown(_:)), "d",
        modifiers: [.command, .shift], target: app)
    shellMenu.addItem(.separator())
    // Workspace section (FR-50): the submenu is app.workspaceMenu, rebuilt in
    // place by the delegate so the ⌃⌘n key equivalents track the live list.
    let workspaceItem = shellMenu.addItem(withTitle: "Workspace", action: nil, keyEquivalent: "")
    shellMenu.setSubmenu(app.workspaceMenu, for: workspaceItem)
    shellMenu.addItem(.separator())
    add("Type Resume Command", to: shellMenu,
        #selector(MemtermAppDelegate.typeResumeCommand(_:)), "r", target: app)
    shellMenu.addItem(.separator())
    // FR-57 kill memories: per-pane and per-tab forget (workspace forget lives
    // in the Workspace submenu's Delete…; the global wipe in the app menu).
    add("Forget Pane Memory", to: shellMenu,
        #selector(MemtermAppDelegate.forgetPaneMemory(_:)), "", modifiers: [], target: app)
    add("Forget Tab Memory", to: shellMenu,
        #selector(MemtermAppDelegate.forgetTabMemory(_:)), "", modifiers: [], target: app)
    shellMenu.addItem(.separator())
    // Council #6: the title is DYNAMIC — "Close Pane" while the focused tab
    // is split, "Close Tab" on its last pane (validateMenuItem retitles it;
    // the slashed compound named neither action honestly).
    add("Close Tab", to: shellMenu, #selector(MemtermAppDelegate.closePane(_:)), "w",
        target: app)

    // Edit — copy:/paste:/selectAll: resolve to the focused terminal view.
    let editMenu = submenu("Edit")
    add("Copy", to: editMenu, #selector(NSText.copy(_:)), "c")
    add("Paste", to: editMenu, #selector(NSText.paste(_:)), "v")
    editMenu.addItem(.separator())
    add("Select All", to: editMenu, #selector(NSText.selectAll(_:)), "a")
    editMenu.addItem(.separator())
    // FR-4: per-pane search over the buffer, restored ghost scrollback included.
    let findItem = editMenu.addItem(withTitle: "Find", action: nil, keyEquivalent: "")
    let findMenu = NSMenu(title: "Find")
    editMenu.setSubmenu(findMenu, for: findItem)
    add("Find…", to: findMenu, #selector(MemtermAppDelegate.findInPane(_:)), "f",
        target: app)
    add("Find Next", to: findMenu, #selector(MemtermAppDelegate.findNextInPane(_:)), "g",
        target: app)
    add("Find Previous", to: findMenu, #selector(MemtermAppDelegate.findPreviousInPane(_:)),
        "g", modifiers: [.command, .shift], target: app)
    // Council #6: the standard ⌘E — the current selection becomes the find
    // bar's term (validated against a usable single-line selection).
    add("Use Selection for Find", to: findMenu,
        #selector(MemtermAppDelegate.useSelectionForFind(_:)), "e", target: app)

    // View
    let viewMenu = submenu("View")
    add("Bigger", to: viewMenu, #selector(MemtermAppDelegate.increaseFontSize(_:)), "+",
        target: app)
    // Hidden alias so plain ⌘= (no shift) also zooms in.
    let biggerAlias = NSMenuItem(title: "Bigger",
                                 action: #selector(MemtermAppDelegate.increaseFontSize(_:)),
                                 keyEquivalent: "=")
    biggerAlias.target = app
    biggerAlias.isHidden = true
    viewMenu.addItem(biggerAlias)
    add("Smaller", to: viewMenu, #selector(MemtermAppDelegate.decreaseFontSize(_:)), "-",
        target: app)
    // Council #6: ⌘0 resets the font to the configured size (Bigger/Smaller
    // drifted with no way home short of Settings).
    add("Actual Size", to: viewMenu, #selector(MemtermAppDelegate.resetFontSize(_:)), "0",
        target: app)
    viewMenu.addItem(.separator())
    add("Clear", to: viewMenu, #selector(MemtermAppDelegate.clearBuffer(_:)), "k", target: app)
    viewMenu.addItem(.separator())
    // feature/serial: the hex lens over a serial pane's stream (⌘⇧X —
    // unclaimed; validated + check-marked by the app delegate).
    add("Hex View", to: viewMenu, #selector(MemtermAppDelegate.toggleHexView(_:)), "x",
        modifiers: [.command, .shift], target: app)
    viewMenu.addItem(.separator())
    let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    let arrows: NSEvent.ModifierFlags = [.command, .option]
    add("Focus Pane Left", to: viewMenu, #selector(MemtermAppDelegate.focusPaneLeft(_:)),
        left, modifiers: arrows, target: app)
    add("Focus Pane Right", to: viewMenu, #selector(MemtermAppDelegate.focusPaneRight(_:)),
        right, modifiers: arrows, target: app)
    add("Focus Pane Up", to: viewMenu, #selector(MemtermAppDelegate.focusPaneUp(_:)),
        up, modifiers: arrows, target: app)
    add("Focus Pane Down", to: viewMenu, #selector(MemtermAppDelegate.focusPaneDown(_:)),
        down, modifiers: arrows, target: app)
    viewMenu.addItem(.separator())
    // Council #6: the standard Enter Full Screen item (⌃⌘F). AppKit retitles
    // it to "Exit Full Screen" while fullscreen — one item, honest both ways.
    add("Enter Full Screen", to: viewMenu, #selector(NSWindow.toggleFullScreen(_:)), "f",
        modifiers: [.control, .command])

    // Window — standard items plus our tab set (all actions target the app
    // delegate's custom-chrome tab plumbing, not NSWindow tab selectors).
    let windowMenu = submenu("Window")
    add("Minimize", to: windowMenu, #selector(NSWindow.performMiniaturize(_:)), "m")
    add("Zoom", to: windowMenu, #selector(NSWindow.performZoom(_:)), "", modifiers: [])
    windowMenu.addItem(.separator())
    // FR-52: ⌘1–⌘8 jump to tab N in the active workspace; ⌘9 = last tab.
    for i in 1...8 {
        let item = NSMenuItem(title: "Tab \(i)",
                              action: #selector(MemtermAppDelegate.selectTab(_:)),
                              keyEquivalent: "\(i)")
        item.target = app
        item.tag = i
        windowMenu.addItem(item)
    }
    let lastTab = NSMenuItem(title: "Last Tab",
                             action: #selector(MemtermAppDelegate.selectTab(_:)),
                             keyEquivalent: "9")
    lastTab.target = app
    lastTab.tag = 9
    windowMenu.addItem(lastTab)
    windowMenu.addItem(.separator())
    // FR-52: ⌘⇧[ / ⌘⇧] previous/next tab, with ⌃Tab / ⌃⇧Tab as hidden
    // aliases — host actions on the app delegate now (plain windows have no
    // native tab group; the NSWindow selectors would dead-key).
    add("Show Previous Tab", to: windowMenu,
        #selector(MemtermAppDelegate.selectPreviousTabAction(_:)), "[",
        modifiers: [.command, .shift], target: app)
    add("Show Next Tab", to: windowMenu,
        #selector(MemtermAppDelegate.selectNextTabAction(_:)), "]",
        modifiers: [.command, .shift], target: app)
    let prevTabAlias = NSMenuItem(title: "Show Previous Tab",
                                  action: #selector(MemtermAppDelegate.selectPreviousTabAction(_:)),
                                  keyEquivalent: "\t")
    prevTabAlias.keyEquivalentModifierMask = [.control, .shift]
    prevTabAlias.isHidden = true
    prevTabAlias.target = app
    windowMenu.addItem(prevTabAlias)
    let nextTabAlias = NSMenuItem(title: "Show Next Tab",
                                  action: #selector(MemtermAppDelegate.selectNextTabAction(_:)),
                                  keyEquivalent: "\t")
    nextTabAlias.keyEquivalentModifierMask = [.control]
    nextTabAlias.isHidden = true
    nextTabAlias.target = app
    windowMenu.addItem(nextTabAlias)
    add("Rename Tab…", to: windowMenu, #selector(MemtermAppDelegate.renameTab(_:)),
        "", modifiers: [], target: app)
    // OUR re-homing implementations (native NSWindow tab selectors are gone
    // with native tabbing): same panes, same processes, different host.
    add("Move Tab to New Window", to: windowMenu,
        #selector(MemtermAppDelegate.moveTabToNewWindowAction(_:)), "", modifiers: [],
        target: app)
    add("Merge All Windows", to: windowMenu,
        #selector(MemtermAppDelegate.mergeAllWindowsAction(_:)), "", modifiers: [],
        target: app)
    windowMenu.addItem(.separator())
    add("Bring All to Front", to: windowMenu, #selector(NSApplication.arrangeInFront(_:)),
        "", modifiers: [])
    NSApp.windowsMenu = windowMenu

    // Help — council #6: About (its standard second home) and the README,
    // which IS the manual for now (bundled into Resources by make-app.sh).
    let helpMenu = submenu("Help")
    add("About memterm", to: helpMenu,
        #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", modifiers: [])
    add("memterm README", to: helpMenu, #selector(MemtermAppDelegate.openReadme(_:)),
        "", modifiers: [], target: app)
    NSApp.helpMenu = helpMenu

    return main
}
