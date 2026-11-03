import Carbon.HIToolbox
import CoreGraphics

enum KeyName: String, CaseIterable, Sendable {
    case tab, enter, space, delete, forwardDelete, home, end, pageUp, pageDown, up, down, left, right, escape
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15, f16, f17, f18, f19, f20

    var keyCode: CGKeyCode {
        let code = switch self {
        case .tab: kVK_Tab
        case .enter: kVK_Return
        case .space: kVK_Space
        case .delete: kVK_Delete
        case .forwardDelete: kVK_ForwardDelete
        case .home: kVK_Home
        case .end: kVK_End
        case .pageUp: kVK_PageUp
        case .pageDown: kVK_PageDown
        case .up: kVK_UpArrow
        case .down: kVK_DownArrow
        case .left: kVK_LeftArrow
        case .right: kVK_RightArrow
        case .escape: kVK_Escape
        case .f1: kVK_F1
        case .f2: kVK_F2
        case .f3: kVK_F3
        case .f4: kVK_F4
        case .f5: kVK_F5
        case .f6: kVK_F6
        case .f7: kVK_F7
        case .f8: kVK_F8
        case .f9: kVK_F9
        case .f10: kVK_F10
        case .f11: kVK_F11
        case .f12: kVK_F12
        case .f13: kVK_F13
        case .f14: kVK_F14
        case .f15: kVK_F15
        case .f16: kVK_F16
        case .f17: kVK_F17
        case .f18: kVK_F18
        case .f19: kVK_F19
        case .f20: kVK_F20
        }
        return CGKeyCode(code)
    }
}

struct KeyCombo: Equatable, Sendable {
    var command, option, control, shift: Bool
    var keyCode: CGKeyCode

    /// Parses `Cmd+Shift+J`: modifiers Cmd, Option, Control, Shift, then one letter, digit or `KeyName`.
    static func parse(_ s: String) -> KeyCombo? {
        var parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.popLast(), let code = keyCode(key) else { return nil }
        var combo = KeyCombo(command: false, option: false, control: false, shift: false, keyCode: code)
        for part in parts {
            switch part {
            case "Cmd": combo.command = true
            case "Option": combo.option = true
            case "Control": combo.control = true
            case "Shift": combo.shift = true
            default: return nil
            }
        }
        return combo
    }

    // shortcut: letters and digits use US ANSI key positions, so other layouts may press a different
    // character; upgrade to a UCKeyTranslate lookup if users report it.
    private static let ansi: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
    ]

    private static func keyCode(_ key: String) -> CGKeyCode? {
        if let name = KeyName(rawValue: key) { return name.keyCode }
        guard key.count == 1, let c = key.lowercased().first, c.isASCII, let code = ansi[c] else { return nil }
        return CGKeyCode(code)
    }
}

enum PlayStep: Equatable, Sendable {
    case paste(String)
    case key(KeyName, count: Int)
    case shortcut(KeyCombo)
    case delay(milliseconds: Int)
    case openApp(path: String)
    case runShortcut(name: String)
    case moveLeft(Int)
}
