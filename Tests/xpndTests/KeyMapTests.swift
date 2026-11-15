import Carbon.HIToolbox
import Testing
@testable import xpnd

@MainActor struct KeyMapTests {
    /// Holds on any Latin layout: a plain letter, its Shift form, and the Space and Tab keys.
    @Test func mapsCharactersToTheKeysThatTypeThem() {
        let map = KeyMap.current()
        let a = try! #require(map.keys["a"])
        let upper = try! #require(map.keys["A"])
        #expect(a.flags.isEmpty)
        #expect(upper.code == a.code && upper.flags == .maskShift)
        #expect(map.keys[" "]?.code == CGKeyCode(kVK_Space))
        #expect(map.keys["\t"]?.code == CGKeyCode(kVK_Tab))
        #expect(map.keys["🙂"] == nil)
    }

    /// Main-block keys win over the keypad, which remote terminals in application keypad mode read as escapes.
    @Test func prefersTheMainBlockOverTheKeypad() throws {
        let us = try #require(Self.layout("com.apple.keylayout.US"))
        #expect(us.keys["*"]?.code == CGKeyCode(kVK_ANSI_8))
        #expect(us.keys["+"]?.code == CGKeyCode(kVK_ANSI_Equal))
        #expect(us.keys["1"]?.code == CGKeyCode(kVK_ANSI_1))
    }

    /// On US International `"` is a dead key: posted alone, the next letter would become `ë`.
    @Test func marksDeadKeys() throws {
        let intl = try #require(Self.layout("com.apple.keylayout.USInternational-PC"))
        #expect(try #require(intl.keys["\""]).dead)
        #expect(intl.keys["a"]?.dead == false)
        #expect(Self.layout("com.apple.keylayout.US")?.keys["\""]?.dead == false)
    }

    private static func layout(_ id: String) -> xpnd.KeyMap? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first,
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return xpnd.KeyMap(layout: Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data)
    }
}
