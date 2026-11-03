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

    @Test func onlyUnmodifiedKeysAreSwallowed() {
        for mods: NSEvent.ModifierFlags in [.command, .control, .option] {
            #expect(!QuickMenuKey.swallows(modifiers: mods))
        }
        #expect(QuickMenuKey.swallows(modifiers: []))
        #expect(QuickMenuKey.swallows(modifiers: .shift))
    }

    /// The panel scrolls to the row whose `.id` is `highlighted`, so it must always name a real row,
    /// and Return must pick the row the highlight is on, past the ninth too.
    @MainActor @Test func highlightStaysOnARowAndReturnPicksIt() {
        let list = (1...12).map { Connection(name: "c\($0)", host: "h") }
        let folder = ConnectionFolder(name: "prod", connections: list)
        var chosen: Connection.ID?
        let state = QuickMenuState(model: QuickMenuModel(library: ConnectionLibrary(folders: [folder]), folder: folder.id),
                                   choose: { chosen = $0 }, cancel: {})
        for _ in 0..<15 { state.handle(.down) }
        #expect(state.highlighted == 11)
        state.handle(.choose)
        #expect(chosen == list[11].id)
        for _ in 0..<15 { state.handle(.up) }
        #expect(state.highlighted == 0)
    }
}
