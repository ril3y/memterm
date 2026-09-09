import AppKit
import Carbon.HIToolbox
import MemtermCore

// Quake-style drop-down terminal (founder ask 2026-09-09): a global hotkey
// slides a terminal panel in from a screen edge and away again — "the old
// school terminal in quake2". The panel is a normal WindowHostController
// with role .dropdown: its tabs are first-class (journaled with role
// "dropdown", restored hidden, archived on close like any tab), it belongs
// to the ACTIVE workspace (hidden with it on a switch, FR-59), and it is
// never slot-matched into the workspace swap. Geometry is
// MemtermCore.DropdownLayout; the hotkey is MemtermCore.HotkeySpec via
// Carbon's RegisterEventHotKey (no Accessibility grant needed).
final class DropdownController {
    private unowned let app: MemtermAppDelegate
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: HotkeySpec?
    /// The panel currently sliding away (ignored by focus-loss hiding).
    private var hiding: WindowHostController?

    static let hotKeySignature: OSType = 0x4D54_4D44  // 'MTMD'

    init(app: MemtermAppDelegate) {
        self.app = app
    }

    deinit { unregisterHotkey() }

    // MARK: - Config

    /// (Re)registers the global hotkey to match the config; called at launch
    /// and from applyConfigLive. Automated runs never register: a real
    /// system-wide hotkey from a probe would fire into the founder's session.
    func applyConfig(_ config: Config) {
        let wanted = config.dropdownEnabled && !ProbeSupport.isUIProbe && !ProbeSupport.isSmoke
            ? HotkeySpec.parse(config.dropdownHotkey) : nil
        guard wanted != registered else { return }
        unregisterHotkey()
        if let wanted { registerHotkey(wanted) }
        // A live change of placement re-lays the panel if it is showing.
        if let host = panelHost, host.window?.isVisible == true, hiding !== host {
            host.window?.setFrame(targetFrame(config), display: true)
        }
    }

    private func registerHotkey(_ spec: HotkeySpec) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return noErr }
            let controller = Unmanaged<DropdownController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { controller.toggle() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
        guard status == noErr else { return }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var ref: EventHotKeyRef?
        let reg = RegisterEventHotKey(spec.keyCode, spec.modifiers.rawValue, hotKeyID,
                                      GetApplicationEventTarget(), 0, &ref)
        if reg == noErr {
            hotKeyRef = ref
            registered = spec
        } else {
            NSLog("memterm: could not register drop-down hotkey %@ (OSStatus %d)", spec.configString, reg)
        }
    }

    private func unregisterHotkey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        registered = nil
    }

    /// MEMTERM_UI_PROBE: what the controller believes is registered.
    var probeRegisteredHotkey: String? { registered?.configString }

    // MARK: - The panel

    /// The active workspace's panel host, if one exists (visible or hidden).
    var panelHost: WindowHostController? {
        app.hosts.first { $0.role == .dropdown && $0.workspaceId == app.activeWorkspaceId }
    }

    var isShowing: Bool {
        guard let host = panelHost, hiding !== host else { return false }
        return host.window?.isVisible == true
    }

    func toggle() {
        if isShowing { hide() } else { show() }
    }

    func show() {
        let config = app.config
        let host = panelHost ?? makePanel()
        guard let window = host.window else { return }
        hiding = nil
        let target = targetFrame(config)
        let hidden = DropdownLayout.hiddenFrame(target: target, screen: screenFrame(config),
                                                edge: edge(config))
        window.setFrame(hidden, display: false)
        window.alphaValue = 1
        if !ProbeSupport.quiet { NSApp.activate(ignoringOtherApps: true) }
        host.focusWindow()  // makeKeyAndOrderFront + the app's focused-host note
        animate(window, to: target, config: config, completion: nil)
    }

    func hide() {
        guard let host = panelHost, let window = host.window, window.isVisible else { return }
        hide(host)
    }

    /// Slide the panel off its edge, then order it out. Called on toggle,
    /// on focus loss (hide_on_focus_loss), and by the workspace switch.
    func hide(_ host: WindowHostController) {
        guard let window = host.window, hiding !== host else { return }
        let config = app.config
        hiding = host
        let target = targetFrame(config)
        let hidden = DropdownLayout.hiddenFrame(target: target, screen: screenFrame(config),
                                                edge: edge(config))
        animate(window, to: hidden, config: config) { [weak self, weak host] in
            guard let self, let host else { return }
            host.window?.orderOut(nil)
            if self.hiding === host { self.hiding = nil }
        }
    }

    /// The panel's window resigned key: slide away unless a sheet took the
    /// key (rename / confirm-close) or a workspace switch is in flight.
    func panelResignedKey(_ host: WindowHostController) {
        guard app.config.dropdownHideOnFocusLoss, !app.isSwitchingWorkspaces,
              host.window?.attachedSheet == nil, hiding !== host else { return }
        hide(host)
    }

    private func makePanel() -> WindowHostController {
        let controller = TerminalWindowController(app: app, workspaceId: app.activeWorkspaceId)
        app.registerController(controller)
        let host = app.makeHost(frame: nil, role: .dropdown)
        host.attach(controller, select: true)
        app.memory?.scheduleTopologySave()
        return host
    }

    // MARK: - Geometry

    private func edge(_ config: Config) -> DropdownLayout.Edge {
        DropdownLayout.Edge(rawValue: config.dropdownEdge) ?? .top
    }

    /// The screen the panel drops on: the one under the mouse (default) or
    /// the main one. Quiet automated runs use a virtual screen parked far
    /// off-screen so the panel never appears on the founder's display.
    func screenFrame(_ config: Config) -> CGRect {
        if ProbeSupport.quiet {
            return CGRect(x: -6000, y: -2000, width: 1600, height: 1000)
        }
        let screen: NSScreen?
        if config.dropdownScreen == "main" {
            screen = NSScreen.main
        } else {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        }
        return screen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func targetFrame(_ config: Config) -> CGRect {
        DropdownLayout.targetFrame(screen: screenFrame(config), edge: edge(config),
                                   width: config.dropdownWidth, height: config.dropdownHeight,
                                   align: DropdownLayout.Align(rawValue: config.dropdownAlign) ?? .center)
    }

    private func animate(_ window: NSWindow, to frame: NSRect, config: Config,
                         completion: (() -> Void)?) {
        let duration = ProbeSupport.quiet || ProbeSupport.isUIProbe
            ? 0 : Double(config.dropdownAnimationMs) / 1000
        guard duration > 0 else {
            window.setFrame(frame, display: true)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: completion)
    }
}
