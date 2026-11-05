/// One step of a keystroke sequence sent to a remote Windows session.
/// Scancodes use FreeRDP's RDP_SCANCODE_* encoding: the extended flag is 0x0100.
enum RDPKeyStep: Equatable, Sendable {
    case scancode(UInt16, down: Bool)
    case text(String)
    case pause(ms: Int)
}

enum RDPKeySequence {
    private static let lCtrl: UInt16 = 0x1D
    private static let lAlt: UInt16 = 0x38
    private static let end: UInt16 = 0x014F
    private static let lWin: UInt16 = 0x015B
    private static let r: UInt16 = 0x13
    private static let v: UInt16 = 0x2F
    private static let enter: UInt16 = 0x1C

    static let ctrlAltDel: [RDPKeyStep] = [
        .scancode(lCtrl, down: true), .scancode(lAlt, down: true),
        .scancode(end, down: true), .scancode(end, down: false),
        .scancode(lAlt, down: false), .scancode(lCtrl, down: false),
    ]

    static let winR: [RDPKeyStep] = [
        .scancode(lWin, down: true), .scancode(r, down: true),
        .scancode(r, down: false), .scancode(lWin, down: false),
    ]

    static let ctrlV: [RDPKeyStep] = [
        .scancode(lCtrl, down: true), .scancode(v, down: true),
        .scancode(v, down: false), .scancode(lCtrl, down: false),
    ]

    /// Win+R, then the drop folder's UNC path, then Enter. The pause lets the Run dialog take focus.
    static func openDropFolder() -> [RDPKeyStep] {
        winR + [
            .pause(ms: 300), .text(#"\\tsclient\xpnd"#),
            .scancode(enter, down: true), .scancode(enter, down: false),
        ]
    }

    /// True when every scancode down is matched by an up in last-in-first-out order.
    /// Non-scancode steps are ignored.
    static func isBalanced(_ steps: [RDPKeyStep]) -> Bool {
        var held: [UInt16] = []
        for step in steps {
            guard case let .scancode(code, down) = step else { continue }
            if down {
                held.append(code)
            } else {
                guard held.last == code else { return false }
                held.removeLast()
            }
        }
        return held.isEmpty
    }
}
