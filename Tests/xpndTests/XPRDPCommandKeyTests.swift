import AppKit
import Testing
import xpndRDP

/// What ⌘ sends Windows. Twice fixed in 0.3.1 (⌘⇧4 and ⌘-scroll opened Start).
struct XPRDPCommandKeyTests {
    /// ⌘ pressed then released with `others` held; the state after, and whether the Windows key was tapped.
    private func pressAndRelease(others: Bool = false, between: (XPCommandState) -> XPCommandState = { $0 },
                                 asWindowsKey: Bool = true) -> (XPCommandState, Bool) {
        var tap: ObjCBool = false
        var state = XPCommandAfterFlags(.up, true, others, asWindowsKey, &tap)
        #expect(!tap.boolValue)
        state = between(state)
        state = XPCommandAfterFlags(state, false, false, asWindowsKey, &tap)
        return (state, tap.boolValue)
    }

    @Test func commandAloneTapsTheWindowsKey() {
        let (state, tap) = pressAndRelease()
        #expect(state == .up)
        #expect(tap)
    }

    @Test func commandAloneTapsNothingWhenItIsCtrl() {
        #expect(pressAndRelease(asWindowsKey: false).1 == false)
    }

    /// macOS keeps ⌘⇧4 to itself, so no key arrives to say ⌘ was used.
    @Test func commandWithAnotherModifierIsNoTap() {
        #expect(pressAndRelease(others: true).1 == false)
    }

    /// A ⌘-click, a ⌘-scroll or a menu's shortcut.
    @Test func commandThatXpndUsedIsNoTap() {
        #expect(pressAndRelease(between: XPCommandAfterUse).1 == false)
    }

    @Test func aKeyWithCommandIsCtrlForEditShortcutsElseWindows() {
        #expect(XPCommandAfterKey(.pending, true, true) == .control)
        #expect(XPCommandAfterKey(.pending, false, true) == .windows)
        #expect(XPCommandAfterKey(.pending, false, false) == .control)
        // A key already sent ⌘ on, so its release isn't a tap either.
        #expect(pressAndRelease(between: { XPCommandAfterKey($0, false, true) }).1 == false)
    }

    @Test func editShortcutsGoByCharacterOrByPositionOffLatinLayouts() {
        #expect(XPIsEditShortcutKey("c", 8, .command))
        #expect(XPIsEditShortcutKey("Z", 6, [.command, .shift]))
        #expect(!XPIsEditShortcutKey("c", 8, [.command, .option]))
        #expect(!XPIsEditShortcutKey("c", 8, []))
        #expect(!XPIsEditShortcutKey("q", 12, .command))
        // Dvorak: the character decides, not the QWERTY position.
        #expect(XPIsEditShortcutKey("c", 34, .command))
        #expect(!XPIsEditShortcutKey("j", 8, .command))
        // Russian: ⌘ and the key where C is reads "с".
        #expect(XPIsEditShortcutKey("с", 8, .command))
        #expect(!XPIsEditShortcutKey("й", 12, .command))
    }

    @Test func wheelFlags() {
        let wheel: UInt16 = 0x0200, negative: UInt16 = 0x0100, hwheel: UInt16 = 0x0400
        #expect(XPWheelFlags(0, 1) == wheel | 120)
        #expect(XPWheelFlags(0, -1) == wheel | negative | (0x100 - 120))
        #expect(XPWheelFlags(0, 5) == wheel | 0xFF)
        #expect(XPWheelFlags(1, 0) == hwheel | negative | (0x100 - 120))
        #expect(XPWheelFlags(0, 0) == 0)
        // A momentum tail: under a 120th of a line, which negated used to be a step of -256.
        #expect(XPWheelFlags(0, -0.005) == 0)
        #expect(XPWheelFlags(0.005, 0) == 0)
    }
}
