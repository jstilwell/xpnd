import Carbon.HIToolbox
import CoreGraphics

/// The key (code and modifiers) that types each character on the current keyboard layout, read from
/// the layout's own data. Remote-desktop apps forward the key code of an event, not its characters,
/// so a typed character must be posted as the key that makes it. Plain keys win over Shift, Option
/// and Shift+Option; main-block keys over the keypad; live keys over dead ones.
struct KeyMap {
    /// `dead`: a dead key (US International's `"`), which types its character only when Space follows.
    typealias Key = (code: CGKeyCode, flags: CGEventFlags, dead: Bool)
    private(set) var keys: [Character: Key] = [:]

    /// Screen Sharing sends a keypad key as one (KP_Multiply), which a terminal in application keypad mode
    /// reads as `ESC O j`, not `*`.
    static let keypad: Set<UInt16> = [0x41, 0x43, 0x45, 0x47, 0x4B, 0x4C, 0x4E, 0x51,
                                      0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C]

    static func current() -> KeyMap {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return KeyMap() }
        return KeyMap(layout: Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data)
    }

    init() {}

    init(layout: Data) {
        let modifiers: [(UInt32, CGEventFlags)] = [
            (0, []), (UInt32(shiftKey >> 8), .maskShift), (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        let all = Array(UInt16(0)..<128)
        let groups = [all.filter { !Self.keypad.contains($0) }, all.filter(Self.keypad.contains)]
        var keys: [Character: Key] = [:]
        var deadKeys: [Character: Key] = [:]
        layout.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            func translate(_ code: UInt16, _ modifier: UInt32, _ options: Int) -> (text: String, dead: Bool)? {
                var state: UInt32 = 0
                var length = 0
                var units = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifier, UInt32(LMGetKbdType()),
                                            OptionBits(options), &state, units.count, &length, &units)
                guard status == noErr else { return nil }
                return (String(utf16CodeUnits: units, count: length), state != 0)
            }
            for group in groups {
                for (modifier, flags) in modifiers {
                    for code in group {
                        guard let live = translate(code, modifier, 0) else { continue }
                        let dead = live.text.isEmpty && live.dead
                        // A dead key on its own types nothing; without dead keys it types the character it stands for.
                        guard let text = dead ? translate(code, modifier, kUCKeyTranslateNoDeadKeysMask)?.text : live.text,
                              text.count == 1, let character = text.first else { continue }
                        if dead {
                            if deadKeys[character] == nil { deadKeys[character] = (CGKeyCode(code), flags, true) }
                        } else if keys[character] == nil {
                            keys[character] = (CGKeyCode(code), flags, false)
                        }
                    }
                }
            }
        }
        self.keys = keys.merging(deadKeys) { live, _ in live }
    }
}
