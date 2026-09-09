import AppKit
import MemtermCore

/// Settings ▸ Appearance: click, press a combination, done. Shows the
/// current hotkey as "⌃`"; while recording shows "Press keys…" and captures
/// the next key-with-modifiers (Esc cancels). Emits the HotkeySpec config
/// spelling through `onChange`.
final class HotkeyRecorderButton: NSButton {
    var spec: HotkeySpec? {
        didSet { refreshTitle() }
    }
    var onChange: ((HotkeySpec) -> Void)?
    private var recording = false {
        didSet { refreshTitle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        recording = true
        window?.makeFirstResponder(self)
    }

    private func refreshTitle() {
        title = recording ? "Press keys…" : (spec?.displayString ?? "Click to set")
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return super.resignFirstResponder()
    }

    /// ⌘-combinations arrive here before keyDown; capture them the same way.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        return capture(event)
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if !capture(event) { super.keyDown(with: event) }
    }

    /// True when the event ended recording (a valid combo, or Esc).
    private func capture(_ event: NSEvent) -> Bool {
        if event.keyCode == 0x35, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            recording = false  // Esc alone cancels
            window?.makeFirstResponder(nil)
            return true
        }
        guard let key = HotkeySpec.keyCodes.first(where: { $0.value == UInt32(event.keyCode) })?.key
        else { return false }
        var mods = HotkeySpec.Modifiers()
        let flags = event.modifierFlags
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        let new = HotkeySpec(modifiers: mods, key: key)
        spec = new
        recording = false
        window?.makeFirstResponder(nil)
        onChange?(new)
        return true
    }
}
