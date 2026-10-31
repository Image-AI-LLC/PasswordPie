import AppKit
import Carbon.HIToolbox

/// A global shortcut stored as a Carbon key code plus Carbon modifier mask.
struct HotKeyConfig: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let `default` = HotKeyConfig(keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey))

    private static let codeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"

    static func load() -> HotKeyConfig {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: codeKey) != nil, defaults.object(forKey: modifiersKey) != nil else {
            return .default
        }
        return HotKeyConfig(
            keyCode: UInt32(defaults.integer(forKey: codeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: HotKeyConfig.codeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: HotKeyConfig.modifiersKey)
    }

    /// Returns nil when the event has no usable modifier; a bare key would hijack typing.
    init?(event: NSEvent) {
        var mask: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        guard flags.intersection([.command, .option, .control]).isEmpty == false else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = mask
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    var keycaps: [String] {
        var keys: [String] = []
        if modifiers & UInt32(controlKey) != 0 { keys.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { keys.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { keys.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { keys.append("⌘") }
        return keys + [HotKeyConfig.keyName(keyCode)]
    }

    var display: String { keycaps.joined() }

    private static func keyName(_ code: UInt32) -> String {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
            kVK_ANSI_9: "9", kVK_ANSI_Backslash: "\\", kVK_ANSI_Slash: "/", kVK_ANSI_Period: ".",
            kVK_ANSI_Comma: ",", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
        ]
        return names[Int(code)] ?? "Key \(code)"
    }
}
