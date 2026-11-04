import Carbon.HIToolbox
import CoreGraphics

/// The key (code and modifiers) that types each character on the current keyboard layout, read from
/// the layout's own data. Remote-desktop apps forward the key code of an event, not its characters,
/// so a typed character must be posted as the key that makes it. Plain keys win over Shift, Option
/// and Shift+Option.
struct KeyMap {
    private(set) var keys: [Character: (code: CGKeyCode, flags: CGEventFlags)] = [:]

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
        var keys: [Character: (code: CGKeyCode, flags: CGEventFlags)] = [:]
        layout.withUnsafeBytes { buffer in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for (modifier, flags) in modifiers {
                for code in UInt16(0)..<128 {
                    var deadKeys: UInt32 = 0
                    var length = 0
                    var units = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifier, UInt32(LMGetKbdType()),
                                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, units.count, &length, &units)
                    guard status == noErr, length > 0 else { continue }
                    let text = String(utf16CodeUnits: units, count: length)
                    guard text.count == 1, let character = text.first, keys[character] == nil else { continue }
                    keys[character] = (CGKeyCode(code), flags)
                }
            }
        }
        self.keys = keys
    }
}
