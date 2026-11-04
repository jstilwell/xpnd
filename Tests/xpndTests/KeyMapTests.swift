import Carbon.HIToolbox
import Testing
@testable import xpnd

struct KeyMapTests {
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
}
