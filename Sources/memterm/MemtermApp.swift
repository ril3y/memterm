import AppKit

// Interactive-mode application delegate: config, main menu, window/tab/pane
// lifecycle. The probe modes (--latency/--flood) keep their own bare delegate
// in App.swift.

final class MemtermAppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.load()
    private(set) var controllers: [TerminalWindowController] = []
    private var fontSize: CGFloat

    override init() {
        fontSize = config.fontSize
        super.init()
    }

    func currentFont() -> NSFont {
        config.resolveFont(size: fontSize)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu(for: self)
        openNewWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Window / tab plumbing

    @discardableResult
    private func openNewWindow() -> TerminalWindowController {
        let controller = TerminalWindowController(app: self)
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    func controllerClosed(_ controller: TerminalWindowController) {
        controllers.removeAll { $0 === controller }
    }

    private func keyController() -> TerminalWindowController? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow,
           let controller = controllers.first(where: { $0.window === window }) {
            return controller
        }
        return controllers.first
    }

    // MARK: - Menu actions

    @objc func newWindow(_ sender: Any?) {
        openNewWindow()
    }

    /// Standard tab mechanism: ⌘T and the native tab bar's "+" both land here.
    @objc func newWindowForTab(_ sender: Any?) {
        let host = keyController()?.window
        let controller = TerminalWindowController(app: self)
        controllers.append(controller)
        if let host, let newWindow = controller.window {
            host.addTabbedWindow(newWindow, ordered: .above)
        }
        controller.showWindow(nil)
    }

    @objc func splitRight(_ sender: Any?) {
        keyController()?.splitCurrentPane(vertical: true)
    }

    @objc func splitDown(_ sender: Any?) {
        keyController()?.splitCurrentPane(vertical: false)
    }

    @objc func closePane(_ sender: Any?) {
        keyController()?.closeCurrentPane()
    }

    @objc func focusPaneLeft(_ sender: Any?) { keyController()?.moveFocus(.left) }
    @objc func focusPaneRight(_ sender: Any?) { keyController()?.moveFocus(.right) }
    @objc func focusPaneUp(_ sender: Any?) { keyController()?.moveFocus(.up) }
    @objc func focusPaneDown(_ sender: Any?) { keyController()?.moveFocus(.down) }

    @objc func openPreferences(_ sender: Any?) {
        NSWorkspace.shared.open(Config.configURL)
    }

    @objc func increaseFontSize(_ sender: Any?) { changeFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { changeFontSize(by: -1) }

    private func changeFontSize(by delta: CGFloat) {
        fontSize = min(72, max(6, fontSize + delta))
        let font = currentFont()
        for controller in controllers { controller.applyFont(font) }
    }

    @objc func clearBuffer(_ sender: Any?) {
        keyController()?.currentPane()?.clearScrollback()
    }
}
