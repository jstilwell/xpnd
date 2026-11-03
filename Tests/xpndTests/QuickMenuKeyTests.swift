import AppKit
import Testing
@testable import xpnd

struct QuickMenuKeyTests {
    private func key(_ code: UInt16, _ chars: String = "", _ mods: NSEvent.ModifierFlags = []) -> QuickMenuKey? {
        QuickMenuKey.key(keyCode: code, characters: chars, modifiers: mods)
    }

    @Test func digits() {
        #expect(key(18, "1") == .pick(1))
        #expect(key(25, "9") == .pick(9))
        #expect(key(29, "0") == nil)
    }

    @Test func navigation() {
        #expect(key(126) == .up)
        #expect(key(125) == .down)
        #expect(key(123) == .back)
        #expect(key(36, "\r") == .choose)
        #expect(key(76, "\u{3}") == .choose)
        #expect(key(53, "\u{1b}") == .close)
    }

    @Test func otherKeysAndModifiersAreNil() {
        #expect(key(18, "1", .command) == nil)
        #expect(key(18, "1", .control) == nil)
        #expect(key(18, "1", .option) == nil)
        #expect(key(0, "a") == nil)
    }
}
