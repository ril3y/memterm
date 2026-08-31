import AppKit

// Programmatic main menu. Without this, ⌘C/⌘V/⌘Q reach nothing — SwiftTerm's
// copy:/paste:/selectAll: only fire via the responder chain from menu items.

func buildMainMenu(for app: MemtermAppDelegate) -> NSMenu {
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
    appMenu.addItem(.separator())
    add("Preferences…", to: appMenu, #selector(MemtermAppDelegate.openPreferences(_:)), ",",
        target: app)
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
    // nil target so the native tab bar's "+" shares the same plumbing
    add("New Tab", to: shellMenu, #selector(MemtermAppDelegate.newWindowForTab(_:)), "t")
    shellMenu.addItem(.separator())
    add("Split Right", to: shellMenu, #selector(MemtermAppDelegate.splitRight(_:)), "d",
        target: app)
    add("Split Down", to: shellMenu, #selector(MemtermAppDelegate.splitDown(_:)), "d",
        modifiers: [.command, .shift], target: app)
    shellMenu.addItem(.separator())
    add("Type Resume Command", to: shellMenu,
        #selector(MemtermAppDelegate.typeResumeCommand(_:)), "r", target: app)
    shellMenu.addItem(.separator())
    add("Close Pane/Tab", to: shellMenu, #selector(MemtermAppDelegate.closePane(_:)), "w",
        target: app)

    // Edit — copy:/paste:/selectAll: resolve to the focused terminal view.
    let editMenu = submenu("Edit")
    add("Copy", to: editMenu, #selector(NSText.copy(_:)), "c")
    add("Paste", to: editMenu, #selector(NSText.paste(_:)), "v")
    editMenu.addItem(.separator())
    add("Select All", to: editMenu, #selector(NSText.selectAll(_:)), "a")

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
    viewMenu.addItem(.separator())
    add("Clear", to: viewMenu, #selector(MemtermAppDelegate.clearBuffer(_:)), "k", target: app)
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

    // Window — standard items plus the native tab set.
    let windowMenu = submenu("Window")
    add("Minimize", to: windowMenu, #selector(NSWindow.performMiniaturize(_:)), "m")
    add("Zoom", to: windowMenu, #selector(NSWindow.performZoom(_:)), "", modifiers: [])
    windowMenu.addItem(.separator())
    add("Show Previous Tab", to: windowMenu, #selector(NSWindow.selectPreviousTab(_:)), "\t",
        modifiers: [.control, .shift])
    add("Show Next Tab", to: windowMenu, #selector(NSWindow.selectNextTab(_:)), "\t",
        modifiers: [.control])
    add("Move Tab to New Window", to: windowMenu, #selector(NSWindow.moveTabToNewWindow(_:)),
        "", modifiers: [])
    add("Merge All Windows", to: windowMenu, #selector(NSWindow.mergeAllWindows(_:)),
        "", modifiers: [])
    windowMenu.addItem(.separator())
    add("Bring All to Front", to: windowMenu, #selector(NSApplication.arrangeInFront(_:)),
        "", modifiers: [])
    NSApp.windowsMenu = windowMenu

    return main
}
