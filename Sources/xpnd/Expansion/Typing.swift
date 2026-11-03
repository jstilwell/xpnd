import Carbon.HIToolbox
import CoreGraphics

/// One key event, reduced to what the typing buffer cares about.
enum KeyInput: Equatable, Sendable {
    case characters(String), backspace, reset, ignore

    private static let resetKeyCodes: Set<Int> = [
        kVK_Return, kVK_Tab, kVK_Space, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow,
        kVK_UpArrow, kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ANSI_KeypadEnter,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func classify(keyCode: UInt16, characters: String, flags: CGEventFlags) -> KeyInput {
        if !flags.isDisjoint(with: [.maskCommand, .maskControl]) { return .reset }
        if keyCode == UInt16(kVK_Delete) { return .backspace }
        if resetKeyCodes.contains(Int(keyCode)) { return .reset }
        if characters.isEmpty { return .ignore } // dead key: the composed character comes next
        // Control characters and the private-use scalars macOS reports for non-printing keys.
        let nonPrintable = characters.unicodeScalars.contains {
            $0.properties.generalCategory == .control || $0.properties.generalCategory == .privateUse
        }
        return nonPrintable ? .reset : .characters(characters)
    }
}

/// Rolling record of the characters typed since the last reset. Never log `text`.
struct TypingBuffer {
    static let capacity = 128
    private(set) var text = ""

    mutating func apply(_ input: KeyInput) {
        switch input {
        case .characters(let s): text = String((text + s).suffix(Self.capacity))
        case .backspace: if !text.isEmpty { text.removeLast() }
        case .reset: text = ""
        case .ignore: break
        }
    }
}

enum Matcher {
    /// The snippet whose keyword the buffer matches; the longest keyword wins.
    static func match(_ buffer: String, in snippets: [Snippet]) -> Snippet? {
        snippets
            .filter { !$0.keyword.isEmpty && ($0.matching == .strict ? buffer == $0.keyword : buffer.hasSuffix($0.keyword)) }
            .max { $0.keyword.count < $1.keyword.count }
    }
}
