import Foundation

// The drop-down terminal's global hotkey, as the config spells it:
// "ctrl+`", "cmd+shift+t", "f12", "opt+space". Parsed here (pure) into the
// Carbon key code + modifier mask the app registers with RegisterEventHotKey,
// and formatted back for the config file and the Settings recorder.
public struct HotkeySpec: Equatable {
    public struct Modifiers: OptionSet, Equatable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        // Carbon modifier masks (HIToolbox Events.h).
        public static let command = Modifiers(rawValue: 1 << 8)   // cmdKey
        public static let shift   = Modifiers(rawValue: 1 << 9)   // shiftKey
        public static let option  = Modifiers(rawValue: 1 << 11)  // optionKey
        public static let control = Modifiers(rawValue: 1 << 12)  // controlKey
    }

    public var modifiers: Modifiers
    /// Canonical key name, lower case ("`", "a", "f12", "space", "esc").
    public var key: String

    public init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// ANSI (US) virtual key codes — the layout the recorder captures and
    /// Carbon expects. Letters, digits, punctuation, function and navigation keys.
    public static let keyCodes: [String: UInt32] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
        "return": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "esc": 0x35,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
        "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79, "forwarddelete": 0x75,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    ]

    private static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    private static let keyAliases: [String: String] = [
        "escape": "esc", "enter": "return", "backtick": "`", "grave": "`", "tilde": "`",
        "spacebar": "space", "backspace": "delete",
    ]

    /// "ctrl+`" / "Cmd + Shift + T" / "f12" → spec; nil for anything Carbon
    /// cannot register (unknown key, modifier-only, empty).
    public static func parse(_ text: String) -> HotkeySpec? {
        let parts = text.lowercased().split(separator: "+").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !parts.isEmpty else { return nil }
        var modifiers = Modifiers()
        var key: String?
        for part in parts {
            if let m = modifierNames[part] {
                modifiers.insert(m)
            } else {
                let name = keyAliases[part] ?? part
                guard key == nil, keyCodes[name] != nil else { return nil }
                key = name
            }
        }
        guard let key else { return nil }
        return HotkeySpec(modifiers: modifiers, key: key)
    }

    public var keyCode: UInt32 { Self.keyCodes[key] ?? 0 }

    /// The config spelling: "ctrl+shift+`".
    public var configString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// The menu/Settings spelling: "⌃⇧`".
    public var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        let names: [String: String] = ["space": "Space", "esc": "Esc", "return": "↩", "tab": "⇥",
                                       "delete": "⌫", "left": "←", "right": "→", "up": "↑", "down": "↓"]
        out += names[key] ?? key.uppercased()
        return out
    }
}
