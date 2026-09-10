import Foundation

// The drop-down terminal's trigger: a key COMBINATION (HotkeySpec, Carbon
// hotkey) or a DOUBLE-TAP of one key ("double-tap ctrl", "double-tap esc" —
// iTerm2's double-tap modifier, Guake's Esc-Esc). Double taps need a global
// event tap (Accessibility) to work outside memterm; inside it a local
// monitor suffices.
public enum DoubleTapKey: String, CaseIterable, Equatable {
    case control = "ctrl", option = "opt", shift = "shift", command = "cmd", escape = "esc"

    public var displayName: String {
        switch self {
        case .control: return "Control"
        case .option: return "Option"
        case .shift: return "Shift"
        case .command: return "Command"
        case .escape: return "Esc"
        }
    }

    public var glyph: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        case .escape: return "Esc"
        }
    }

    public var isModifier: Bool { self != .escape }

    static let aliases: [String: DoubleTapKey] = [
        "ctrl": .control, "control": .control, "⌃": .control,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "shift": .shift, "⇧": .shift,
        "cmd": .command, "command": .command, "⌘": .command,
        "esc": .escape, "escape": .escape,
    ]
}

public enum DropdownTrigger: Equatable {
    case combo(HotkeySpec)
    case doubleTap(DoubleTapKey)

    public static let doubleTapPrefix = "double-tap "

    /// "ctrl+`" → .combo; "double-tap ctrl" / "Double-Tap Esc" → .doubleTap;
    /// nil for anything unusable.
    public static func parse(_ text: String) -> DropdownTrigger? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasPrefix(doubleTapPrefix) {
            let name = lower.dropFirst(doubleTapPrefix.count).trimmingCharacters(in: .whitespaces)
            return DoubleTapKey.aliases[name].map { .doubleTap($0) }
        }
        return HotkeySpec.parse(trimmed).map { .combo($0) }
    }

    public var configString: String {
        switch self {
        case .combo(let spec): return spec.configString
        case .doubleTap(let key): return Self.doubleTapPrefix + key.rawValue
        }
    }

    public var displayString: String {
        switch self {
        case .combo(let spec): return spec.displayString
        case .doubleTap(let key): return "Double-tap \(key.glyph)"
        }
    }

    public var isDoubleTap: Bool {
        if case .doubleTap = self { return true }
        return false
    }
}

/// Pure double-tap recognition. Feed every press/release of the watched key
/// (modifiers: flag set / cleared; Esc: key down / up) and every OTHER key
/// press as an interruption. Fires on the second clean press within
/// `window` seconds of the first; a third press starts over.
public struct DoubleTapDetector: Equatable {
    public var window: TimeInterval
    private var firstPressAt: TimeInterval?
    private var releasedSinceFirst = false
    private var down = false

    public init(window: TimeInterval = 0.35) {
        self.window = window
    }

    /// Returns true when this press completes a double tap.
    public mutating func press(at t: TimeInterval) -> Bool {
        guard !down else { return false }  // key repeat / duplicate press
        down = true
        if let first = firstPressAt, releasedSinceFirst, t - first <= window {
            firstPressAt = nil
            releasedSinceFirst = false
            return true
        }
        firstPressAt = t
        releasedSinceFirst = false
        return false
    }

    public mutating func release(at t: TimeInterval) {
        down = false
        if let first = firstPressAt {
            if t - first <= window { releasedSinceFirst = true } else { firstPressAt = nil }
        }
    }

    /// Any other key while a tap is pending (⌃C is not a tap of ⌃).
    public mutating func interrupt() {
        firstPressAt = nil
        releasedSinceFirst = false
    }
}
