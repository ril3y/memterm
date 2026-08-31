import AppKit

// Interactive-mode application delegate: config, main menu, window/tab/pane
// lifecycle. The probe modes (--latency/--flood) keep their own bare delegate
// in App.swift.

final class MemtermAppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.load()
    private(set) var controllers: [TerminalWindowController] = []
    private var fontSize: CGFloat
    private(set) var memory: MemoryEngine?
    /// Set before windows close at quit so their teardown isn't captured.
    private(set) var isTerminating = false
    private let smokeMode: Bool

    init(smokeMode: Bool = false) {
        self.smokeMode = smokeMode
        fontSize = config.fontSize
        super.init()
    }

    func currentFont() -> NSFont {
        config.resolveFont(size: fontSize)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu(for: self)

        // FR-24: one restore pipeline, exercised on every normal launch.
        let engine = MemoryEngine(app: self, config: config)
        memory = engine
        let restored = engine.loadStateForRestore()
        if restored.isEmpty {
            openNewWindow()
        } else {
            restoreWindows(restored)
        }
        engine.start()
        engine.scheduleTopologySave()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification, object: nil)

        NSApp.activate(ignoringOtherApps: true)
        if smokeMode { runSmoke(restoredWindows: restored) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        memory?.flushSync()   // windows still open: the snapshot is the live layout
        isTerminating = true
        return .terminateNow
    }

    @objc private func workspaceWillPowerOff(_ note: Notification) {
        memory?.flushSync()
    }

    // MARK: - Restore

    private func restoreWindows(_ windows: [WindowRestore]) {
        var focusTarget: TerminalWindowController?
        for win in windows {
            var host: TerminalWindowController?
            for (i, tab) in win.tabs.enumerated() {
                let frame = i == 0 ? parseFrame(win.frame) : nil
                let controller = TerminalWindowController(app: self, restoredTab: tab,
                                                          restoredFrame: frame)
                controllers.append(controller)
                if i == 0 {
                    host = controller
                } else if let hostWindow = host?.window, let newWindow = controller.window {
                    hostWindow.addTabbedWindow(newWindow, ordered: .above)
                }
                controller.showWindow(nil)
                if controller.tabId == win.focusedTab || focusTarget == nil {
                    focusTarget = controller
                }
            }
        }
        focusTarget?.window?.makeKeyAndOrderFront(nil)
    }

    private func parseFrame(_ s: String?) -> NSRect? {
        guard let s else { return nil }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 50, parts[3] > 50 else { return nil }
        return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    // MARK: - Smoke test (deterministic capture/restore gate, no interaction)

    private func runSmoke(restoredWindows: [WindowRestore]) {
        if restoredWindows.isEmpty {
            // Run 1: build 1 window / 2 tabs / 3 panes, cd one pane, let the
            // 2 s poll capture it, flush, report what the store holds.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.controllers.first?.splitCurrentPane(vertical: true)
                self.newWindowForTab(nil)
                self.controllers.first?.allPanes().first?.send(txt: "cd /tmp\r")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                self.memory?.flushSync()
                guard let counts = self.memory?.store.counts() else { exit(1) }
                print("SMOKE-SAVED windows=\(counts.windows) tabs=\(counts.tabs) panes=\(counts.panes)")
                exit(0)
            }
        } else {
            // Run 2: report what the restore pipeline actually rebuilt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let windows = MemoryEngine.groupedControllers(self.controllers).count
                let panes = self.controllers.flatMap { $0.allPanes() }
                let cwds = panes.compactMap { $0.lastKnownCwd }
                print("SMOKE-RESTORED windows=\(windows) tabs=\(self.controllers.count) panes=\(panes.count) cwds=\(cwds)")
                exit(0)
            }
        }
    }

    // MARK: - Window / tab plumbing

    @discardableResult
    private func openNewWindow() -> TerminalWindowController {
        let controller = TerminalWindowController(app: self)
        controllers.append(controller)
        controller.showWindow(nil)
        memory?.scheduleTopologySave()
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
        memory?.scheduleTopologySave()
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

    /// ⌘R: types the captured resume command into the pty WITHOUT a newline —
    /// the user must press Enter themselves (FR-29, no exceptions).
    @objc func typeResumeCommand(_ sender: Any?) {
        guard let pane = keyController()?.currentPane(),
              let command = pane.pendingResumeCommand else { return }
        pane.send(txt: command)
        pane.pendingResumeCommand = nil
    }
}
