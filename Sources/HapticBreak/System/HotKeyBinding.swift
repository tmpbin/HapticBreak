import AppKit
import Carbon.HIToolbox

/// One user-editable global shortcut: a Carbon key code plus Carbon modifier flags.
/// Persisted as JSON inside Settings; rendered as macOS-style glyphs (⌃⌥Space).
struct HotKeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (`controlKey` / `optionKey` / `shiftKey` / `cmdKey`).
    var modifiers: UInt32

    /// Build from a captured keyboard event; nil when no real modifier is held
    /// (bare keys would swallow normal typing system-wide).
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        // Require ⌃ / ⌥ / ⌘ (shift alone still collides with plain typing).
        guard carbon & ~UInt32(shiftKey) != 0 else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbon
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Display string in system convention: modifier glyphs in ⌃⌥⇧⌘ order + key cap name.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + Self.keyName(for: keyCode)
    }

    /// Human-readable key cap for a Carbon virtual key code (US layout for letters/digits;
    /// glyphs for editing/navigation keys).
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        // Letters / digits / punctuation via the ANSI table.
        if let printable = printableKeyNames[Int(keyCode)] { return printable }
        return "Key\(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "⏎", kVK_ANSI_KeypadEnter: "⌤",
        kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let printableKeyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
    ]
}

/// The app's four global shortcuts, as one persistable value (tolerant decoding: fields added
/// later fall back to their defaults).
struct HotKeyBindings: Codable, Equatable {
    var pause: HotKeyBinding
    var skip: HotKeyBinding
    var buzz: HotKeyBinding
    var acknowledge: HotKeyBinding

    static let defaults = HotKeyBindings(
        pause:       HotKeyBinding(keyCode: UInt32(kVK_Space),  modifiers: UInt32(controlKey) | UInt32(optionKey)),
        skip:        HotKeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey) | UInt32(optionKey)),
        buzz:        HotKeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey) | UInt32(optionKey)),
        acknowledge: HotKeyBinding(keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey) | UInt32(optionKey)))

    init(pause: HotKeyBinding, skip: HotKeyBinding, buzz: HotKeyBinding, acknowledge: HotKeyBinding) {
        self.pause = pause
        self.skip = skip
        self.buzz = buzz
        self.acknowledge = acknowledge
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pause       = try c.decodeIfPresent(HotKeyBinding.self, forKey: .pause)       ?? Self.defaults.pause
        skip        = try c.decodeIfPresent(HotKeyBinding.self, forKey: .skip)        ?? Self.defaults.skip
        buzz        = try c.decodeIfPresent(HotKeyBinding.self, forKey: .buzz)        ?? Self.defaults.buzz
        acknowledge = try c.decodeIfPresent(HotKeyBinding.self, forKey: .acknowledge) ?? Self.defaults.acknowledge
    }

    /// True when all four combos are distinct (a duplicate would make one action unreachable).
    var hasNoDuplicates: Bool {
        Set([pause, skip, buzz, acknowledge]).count == 4
    }
}
