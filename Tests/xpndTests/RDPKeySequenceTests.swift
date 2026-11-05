import Testing
@testable import xpnd

@Suite struct RDPKeySequenceTests {
    @Test func sequencesAreBalanced() {
        #expect(RDPKeySequence.isBalanced(RDPKeySequence.ctrlAltDel))
        #expect(RDPKeySequence.isBalanced(RDPKeySequence.winR))
        #expect(RDPKeySequence.isBalanced(RDPKeySequence.ctrlV))
        #expect(RDPKeySequence.isBalanced(RDPKeySequence.openDropFolder()))
    }

    @Test func unbalancedSequencesAreNotBalanced() {
        // Key left down, wrong-order up, and unmatched up must all fail.
        #expect(!RDPKeySequence.isBalanced([.scancode(0x1D, down: true)]))
        #expect(!RDPKeySequence.isBalanced([
            .scancode(0x1D, down: true), .scancode(0x38, down: true),
            .scancode(0x1D, down: false), .scancode(0x38, down: false),
        ]))
        #expect(!RDPKeySequence.isBalanced([.scancode(0x1D, down: false)]))
    }

    @Test func ctrlAltDelIsCtrlAltEnd() {
        let downs = RDPKeySequence.ctrlAltDel.compactMap { step -> UInt16? in
            if case let .scancode(code, down: true) = step { return code }
            return nil
        }
        #expect(downs == [0x1D, 0x38, 0x014F])
    }

    @Test func ctrlVIsCtrlAndV() {
        #expect(RDPKeySequence.ctrlV == [
            .scancode(0x1D, down: true), .scancode(0x2F, down: true),
            .scancode(0x2F, down: false), .scancode(0x1D, down: false),
        ])
    }

    @Test func openDropFolderTypesThePath() {
        let steps = RDPKeySequence.openDropFolder()
        #expect(steps.starts(with: RDPKeySequence.winR))
        #expect(steps.contains(.text(#"\\tsclient\xpnd"#)))
        let textIndex = steps.firstIndex(of: .text(#"\\tsclient\xpnd"#))
        #expect(textIndex != nil)
        if let i = textIndex {
            #expect(steps[i - 1] == .pause(ms: 300))
            #expect(Array(steps[(i + 1)...]) == [
                .scancode(0x1C, down: true), .scancode(0x1C, down: false),
            ])
        }
    }
}
