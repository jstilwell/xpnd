import Carbon.HIToolbox
import CoreGraphics

/// One key event, reduced to what the typing buffer cares about.
enum KeyInput: Equatable, Sendable {
    /// `boundary`: a space, which ends the word and may fire a strict keyword before it.
    case characters(String), boundary(String), backspace, reset, ignore

    private static let resetKeyCodes: Set<Int> = [
        kVK_Return, kVK_Tab, kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow,
        kVK_UpArrow, kVK_ForwardDelete, kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ANSI_KeypadEnter,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    static func classify(keyCode: UInt16, characters: String, flags: CGEventFlags) -> KeyInput {
        if !flags.isDisjoint(with: [.maskCommand, .maskControl]) { return .reset }
        if keyCode == UInt16(kVK_Space) { return .boundary(" ") }
        // ⌥⌫ deletes a word on screen, so the buffer can't follow it one character at a time.
        if keyCode == UInt16(kVK_Delete) { return flags.contains(.maskAlternate) ? .reset : .backspace }
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
        case .reset, .boundary: text = ""
        case .ignore: break
        }
    }
}

enum Matcher {
    /// Characters that may open a word, so `(;sig ` still expands.
    private static let opening: Set<Character> = ["(", "[", "{", "<", "\"", "'", "`"]

    /// A space, or punctuation or a symbol: what ends a word for a strict keyword.
    static func isBoundary(_ c: Character) -> Bool { c == " " || c.isPunctuation || c.isSymbol }

    /// The loose snippet the buffer ends with, longest first; it fires as soon as it's typed.
    static func instant(_ buffer: String, in snippets: [Snippet]) -> Snippet? {
        snippets
            .filter { $0.matching == .loose && !$0.keyword.isEmpty && buffer.hasSuffix($0.keyword) }
            .max { $0.keyword.count < $1.keyword.count }
    }

    /// The strict snippet `boundary`, just typed after `word`, fires. The word may follow opening characters
    /// (`(;sig`), but not letters (`don't`). A keyword that continues with `boundary` (`;sig.`) is still being typed.
    static func strict(word: String, boundary: Character, in snippets: [Snippet]) -> Snippet? {
        guard isBoundary(boundary) else { return nil }
        let strict = snippets.filter { $0.matching == .strict && !$0.keyword.isEmpty }
        return strict
            .filter { snippet in
                guard word.hasSuffix(snippet.keyword) else { return false }
                let before = word.dropLast(snippet.keyword.count)
                return before.allSatisfy(opening.contains)
            }
            .filter { candidate in !strict.contains { $0.keyword.hasPrefix(candidate.keyword + String(boundary)) } }
            .max { $0.keyword.count < $1.keyword.count }
    }

}
