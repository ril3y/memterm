import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MemtermCore

// Quake-style drop-down terminal (founder ask 2026-09-09): a global hotkey
// slides a terminal panel in from a screen edge and away again — "the old
// school terminal in quake2".
//
// One window (founder 2026-10-02, built 2026-11-23; spec 2026-10-02 §5/§7):
// "There should ONLY be one memterm window ever visible, so if you select
// quake style it should be that window with all the current tabs and
// workspaces; if you unselect it it should be the opposite." The panel is
// therefore a PRESENTATION of the active workspace's own window
// (WindowHostController.enterPanelPresentation), not a second host: same
// tabs, same workspace bar, same journal rows (resting frame, no role).
// Turning the mode off restores the window's frame, level and style.
// Geometry is MemtermCore.DropdownLayout; the hotkey is
// MemtermCore.HotkeySpec via Carbon's RegisterEventHotKey (no Accessibility
// grant needed).
final class DropdownController {
    private unowned let app: MemtermAppDelegate
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: HotkeySpec?
    /// Double-tap trigger state (DropdownTrigger.doubleTap): the watched
    /// key, the pure detector, and whichever event source is feeding it —
    /// a listen-only session event tap when Accessibility is granted (works
    /// everywhere), else a local monitor (works while memterm is frontmost).
    private var doubleTapKey: DoubleTapKey?
    private var detector = DoubleTapDetector()
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var localMonitor: Any?
    private var accessibilityPrompted = false
    /// While a double-tap trigger runs on the local-monitor fallback, poll
    /// for the Accessibility grant and upgrade to the system-wide tap the
    /// moment it lands (founder 2026-09-09: "have the program in focus to
    /// have the hotkey work" — the grant arrived after launch and nothing
    /// re-checked until a relaunch).
    private var grantPoll: Timer?
    /// The panel currently sliding away (ignored by focus-loss hiding).
    private var hiding: WindowHostController?
    /// Bumped by every show/hide/mode change: a slide-away completion only
    /// orders the window out if nothing happened since it started (a quick
    /// hide → show must not vanish when the old slide finishes).
    private var generation = 0
    /// Whether the mode was on at the last applyConfig: its edges (on → the
    /// window becomes the panel and shows; off → it goes back) run once.
    private var modeEnabled = false

    static let hotKeySignature: OSType = 0x4D54_4D44  // 'MTMD'

    init(app: MemtermAppDelegate) {
        self.app = app
    }

    deinit {
        unregisterHotkey()
        stopDoubleTap()
    }

    // MARK: - Config

    /// (Re)registers the global hotkey to match the config; called at launch
    /// and from applyConfigLive. Automated runs never register: a real
    /// system-wide hotkey from a probe would fire into the founder's session.
    func applyConfig(_ config: Config) {
        let automated = ProbeSupport.isUIProbe || ProbeSupport.isSmoke
        let trigger = config.dropdownEnabled ? DropdownTrigger.parse(config.dropdownHotkey) : nil
        // Combo → Carbon hotkey (never in automated runs: a real system-wide
        // hotkey from a probe would fire into the founder's session).
        var wantedCombo: HotkeySpec?
        if case .combo(let spec)? = trigger, !automated { wantedCombo = spec }
        if wantedCombo != registered {
            unregisterHotkey()
            if let wantedCombo { registerHotkey(wantedCombo) }
        }
        // Double-tap → event sources (the DETECTOR runs in automated runs so
        // the probe can feed it synthetic taps; the event tap / monitor
        // never start there).
        var wantedTap: DoubleTapKey?
        if case .doubleTap(let key)? = trigger { wantedTap = key }
        if wantedTap != doubleTapKey {
            stopDoubleTap()
            doubleTapKey = wantedTap
            detector = DoubleTapDetector()
            if wantedTap != nil, !automated { startDoubleTap() }
        }
        // Mode edges (spec §7): switching quake style on turns the active
        // workspace's window into the panel and shows it there; switching it
        // off puts every panel back as a normal window.
        if config.dropdownEnabled != modeEnabled {
            modeEnabled = config.dropdownEnabled
            if modeEnabled {
                show()
            } else {
                leavePanelMode()
            }
            return
        }
        // A live change of placement re-lays the panel if it is showing.
        if let host = panelHost, host.window?.isVisible == true, hiding !== host {
            host.window?.setFrame(targetFrame(config), display: true)
        }
    }

    /// Quake style switched off: the panel goes back to being a normal
    /// window — saved frame, level, style — and stays on screen if it
    /// belongs to the active workspace.
    private func leavePanelMode() {
        hiding = nil
        generation += 1
        // Every host, not just panels: one may still be waiting on a
        // full-screen exit before it becomes the panel.
        for host in app.hosts { host.cancelPendingPanelEntry() }
        let panels = app.hosts.filter(\.isPanel)
        for host in panels { host.exitPanelPresentation() }
        // FR-59 again: every window of the active workspace is on screen,
        // including any the mode kept hidden; the former panel takes focus.
        let active = app.activeWorkspaceId
        for host in app.hosts where host.workspaceId == active && !host.tabs.isEmpty {
            host.window?.alphaValue = 1
            host.showWindow(nil)
        }
        panels.first { $0.workspaceId == active }?.focusWindow()
    }

    // MARK: - Double-tap trigger

    /// Accessibility is what lets a listen-only event tap see keys while
    /// another app is frontmost. Asked for once per launch when a
    /// double-tap trigger is enabled without it; Settings has a button too.
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// True when a system-wide double-tap source is live (the event tap).
    var doubleTapIsGlobal: Bool { eventTap != nil }

    private func startDoubleTap() {
        if Self.accessibilityGranted, startEventTap() { return }
        if !accessibilityPrompted {
            accessibilityPrompted = true
            Self.promptForAccessibility()
        }
        // Fallback: memterm-frontmost coverage via a local monitor (it can
        // at least HIDE the panel, and shows it while memterm is active).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.feed(nsEvent: event)
            return event
        }
        grantPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard Self.accessibilityGranted else { return }
            timer.invalidate()
            self.grantPoll = nil
            if let localMonitor = self.localMonitor { NSEvent.removeMonitor(localMonitor) }
            self.localMonitor = nil
            if !self.startEventTap() {
                // Tap refused despite the grant (rare): keep the fallback.
                self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                    self?.feed(nsEvent: event)
                    return event
                }
            }
        }
    }

    private func stopDoubleTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            if let eventTapSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            }
        }
        eventTap = nil
        eventTapSource = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        grantPoll?.invalidate()
        grantPoll = nil
    }

    private func startEventTap() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<DropdownController>.fromOpaque(userInfo).takeUnretainedValue()
            controller.feed(cgType: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                          callback: callback, userInfo: selfPtr) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        eventTapSource = source
        return true
    }

    private static let modifierKeyCodes: [Int64: DoubleTapKey] = [
        0x3B: .control, 0x3E: .control,   // left / right control
        0x3A: .option, 0x3D: .option,
        0x38: .shift, 0x3C: .shift,
        0x37: .command, 0x36: .command,
    ]

    private func feed(cgType type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .flagsChanged:
            guard let key = Self.modifierKeyCodes[code] else { return }
            let flags = event.flags
            let held: Bool
            switch key {
            case .control: held = flags.contains(.maskControl)
            case .option: held = flags.contains(.maskAlternate)
            case .shift: held = flags.contains(.maskShift)
            case .command: held = flags.contains(.maskCommand)
            case .escape: return
            }
            DispatchQueue.main.async { self.tap(key, pressed: held, at: now) }
        case .keyDown:
            let repeatFlag = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if code == 0x35 {
                guard !repeatFlag else { return }
                DispatchQueue.main.async {
                    self.tap(.escape, pressed: true, at: now)
                    self.tap(.escape, pressed: false, at: now)
                }
            } else {
                DispatchQueue.main.async { self.otherKey() }
            }
        default:
            return
        }
    }

    private func feed(nsEvent event: NSEvent) {
        let now = event.timestamp
        switch event.type {
        case .flagsChanged:
            guard let key = Self.modifierKeyCodes[Int64(event.keyCode)] else { return }
            let flags = event.modifierFlags
            let held: Bool
            switch key {
            case .control: held = flags.contains(.control)
            case .option: held = flags.contains(.option)
            case .shift: held = flags.contains(.shift)
            case .command: held = flags.contains(.command)
            case .escape: return
            }
            tap(key, pressed: held, at: now)
        case .keyDown:
            if event.keyCode == 0x35 {
                guard !event.isARepeat else { return }
                tap(.escape, pressed: true, at: now)
                tap(.escape, pressed: false, at: now)
            } else {
                otherKey()
            }
        default:
            return
        }
    }

    /// One press or release of a candidate key; fires the toggle on a clean
    /// double tap of THE watched key. Other watched-class keys interrupt.
    func tap(_ key: DoubleTapKey, pressed: Bool, at time: TimeInterval) {
        guard let watched = doubleTapKey else { return }
        guard key == watched else {
            if pressed { detector.interrupt() }
            return
        }
        if pressed {
            if detector.press(at: time) { toggle() }
        } else {
            detector.release(at: time)
        }
    }

    func otherKey() {
        detector.interrupt()
    }

    /// MEMTERM_UI_PROBE: the parsed trigger the controller is honoring.
    var probeTrigger: String? {
        if let registered { return registered.configString }
        if let doubleTapKey { return DropdownTrigger.doubleTap(doubleTapKey).configString }
        return nil
    }

    /// MEMTERM_DROPDOWN_TRACE=1: log registration + every hotkey delivery.
    static let trace = ProcessInfo.processInfo.environment["MEMTERM_DROPDOWN_TRACE"] == "1"

    private func registerHotkey(_ spec: HotkeySpec) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // The EVENT DISPATCHER target, not the application target: hot-key
        // events are dispatched to the app's dispatcher; handlers installed
        // on the application target only see them while the app is active
        // (founder 2026-09-09: "have to have memterm in focus for any hotkey
        // to work"). This is what MASShortcut / HotKey register against.
        let status = InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let controller = Unmanaged<DropdownController>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == DropdownController.hotKeySignature else { return OSStatus(eventNotHandledErr) }
            if DropdownController.trace { NSLog("memterm dropdown: hotkey fired (app active=%d)", NSApp.isActive ? 1 : 0) }
            DispatchQueue.main.async { controller.toggle() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)
        guard status == noErr else {
            NSLog("memterm: could not install the drop-down hotkey handler (OSStatus %d)", status)
            return
        }
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        var ref: EventHotKeyRef?
        let reg = RegisterEventHotKey(spec.keyCode, spec.modifiers.rawValue, hotKeyID,
                                      GetEventDispatcherTarget(), 0, &ref)
        if reg == noErr {
            hotKeyRef = ref
            registered = spec
            NSLog("memterm dropdown: registered global hotkey %@ (code %u, mods %u)", spec.configString, spec.keyCode, spec.modifiers.rawValue)
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

    /// The host presented as the panel right now (visible or slid away).
    var panelHost: WindowHostController? {
        app.hosts.first { $0.isPanel }
    }

    var isShowing: Bool {
        guard let host = panelHost, hiding !== host,
              host.workspaceId == app.activeWorkspaceId else { return false }
        return host.window?.isVisible == true
    }

    /// The hotkey, the menu item and the double-tap all land here. With
    /// quake style off there is no panel to toggle (the window is a window).
    func toggle() {
        guard app.config.dropdownEnabled else { return }
        if isShowing { hide() } else { show() }
    }

    func show() {
        let config = app.config
        guard config.dropdownEnabled else { return }
        // Founder 2026-09-09: with every tab closed, the hotkey must still
        // produce a terminal — in the Default workspace when the active one
        // is gone (its last user close removed it).
        _ = app.workspaceForDropdown()
        let host = adoptPanelHost()
        // One window, before anything is presented (even while a full-screen
        // exit is still pending).
        hideOtherWindows(than: host)
        // Entering from native full screen finishes after the exit
        // animation; show() runs again then and re-checks everything.
        guard host.isPanel, let window = host.window else {
            host.enterPanelPresentation { [weak self] in self?.show() }
            return
        }
        let target = targetFrame(config)
        // Already down and in place (e.g. a workspace switch that kept the
        // window): just take focus, no second slide.
        if isShowing, window.frame.equalTo(target) {
            host.focusWindow()
            return
        }
        hiding = nil
        generation += 1
        let hidden = DropdownLayout.hiddenFrame(target: target, screen: screenFrame(config),
                                                edge: edge(config))
        // A slide-away may still be running (hide → show in quick
        // succession): settle it first, or the two animations fight and the
        // panel stops part-way (visible-probe finding, 2026-11-23).
        Self.settleFrame(window, at: hidden)
        window.alphaValue = 1
        if Self.trace { NSLog("memterm dropdown: show (app active=%d)", NSApp.isActive ? 1 : 0) }
        if !ProbeSupport.quiet {
            // Cooperative activation (macOS 14): ask both ways so a hotkey
            // from another app brings keyboard focus to the panel.
            NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)
        }
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
        generation += 1
        let started = generation
        let target = targetFrame(config)
        let hidden = DropdownLayout.hiddenFrame(target: target, screen: screenFrame(config),
                                                edge: edge(config))
        // Same in reverse: a slide-in still running stops where it is.
        Self.settleFrame(window, at: window.frame)
        animate(window, to: hidden, config: config) { [weak self, weak host] in
            guard let self, let host, self.generation == started,
                  self.hiding === host, host.isPanel else { return }
            // The panel has slid off its edge; releasing its drawables here
            // costs a redraw on the next hotkey and saves a window-sized
            // backing store per workspace in between.
            host.orderOutReleasingSurfaces()
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

    /// The active workspace's window, to present as the panel. A panel left
    /// on another workspace (a switch that built fresh windows) goes back to
    /// being a normal hidden window first, so exactly one panel exists. With
    /// no window at all (every tab closed), a fresh one is made — a normal
    /// host with one new tab, presented as the panel.
    @discardableResult
    private func adoptPanelHost() -> WindowHostController {
        let active = app.activeWorkspaceId
        if let host = panelHost, host.workspaceId == active { return host }
        for stale in app.hosts where stale.isPanel || stale.workspaceId != active {
            stale.cancelPendingPanelEntry()
            guard stale.isPanel else { continue }
            if hiding === stale { hiding = nil }
            if stale.window?.isVisible == true { stale.orderOutReleasingSurfaces() }
            stale.exitPanelPresentation()
        }
        // show() presents it (enterPanelPresentation), which may wait for
        // a native full-screen exit first.
        return app.primaryHost(ofWorkspace: active) ?? makeWindow(in: active)
    }

    private func makeWindow(in workspaceId: String) -> WindowHostController {
        let controller = TerminalWindowController(app: app, workspaceId: workspaceId)
        app.registerController(controller)
        let host = app.makeHost(frame: nil)
        host.attach(controller, select: true)
        app.memory?.scheduleTopologySave()
        app.refreshWorkspaceChips()
        return host
    }

    /// Spec §7, one window: while quake style is on, any other memterm
    /// window that came on screen (a multi-window workspace restored, a
    /// swap's extra groups) is hidden. Its tabs stay live and journaled as
    /// a hidden holder — nothing merges or closes; turning the mode off or
    /// Window ▸ Merge All Windows brings them back.
    private func hideOtherWindows(than panel: WindowHostController) {
        for host in app.hosts where host !== panel && host.window?.isVisible == true {
            host.orderOutReleasingSurfaces()
        }
    }

    /// After every workspace switch (spec §7): with quake style on, the
    /// incoming workspace's window is the panel and is down. A swap kept
    /// the same window (nothing to move); a switch that built fresh windows
    /// moves the panel to them.
    func activeWorkspaceChanged() {
        guard app.config.dropdownEnabled else { return }
        show()
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

    /// Ends any frame animation in flight and puts the window at `frame`. A
    /// zero-length animation group replaces the running one; the plain
    /// setFrame makes the model frame exact.
    static func settleFrame(_ window: NSWindow, at frame: NSRect) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0
            window.animator().setFrame(frame, display: false)
        })
        window.setFrame(frame, display: false)
    }

    /// MEMTERM_UI_PROBE: a real slide duration for the race legs (automated
    /// runs otherwise slide instantly).
    var probeSlideSeconds: Double?

    private func animate(_ window: NSWindow, to frame: NSRect, config: Config,
                         completion: (() -> Void)?) {
        let duration = probeSlideSeconds ?? (ProbeSupport.quiet || ProbeSupport.isUIProbe
            ? 0 : Double(config.dropdownAnimationMs) / 1000)
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
