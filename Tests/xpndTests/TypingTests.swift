import CoreGraphics
import Testing
@testable import xpnd

@Suite struct TypingTests {
    private func snip(_ keyword: String, _ mode: MatchingMode) -> Snippet {
        Snippet(name: keyword, keyword: keyword, matching: mode, text: "x")
    }

    @Test func strictNeedsExactBuffer() {
        let s = [snip(";sig", .strict)]
        #expect(Matcher.match(";sig", in: s)?.keyword == ";sig")
        #expect(Matcher.match("x;sig", in: s) == nil)
    }

    @Test func looseMatchesSuffix() {
        #expect(Matcher.match("First==>", in: [snip("==>", .loose)])?.keyword == "==>")
    }

    @Test func longestKeywordWins() {
        let s = [snip("sig", .loose), snip(";sig", .strict)]
        #expect(Matcher.match(";sig", in: s)?.keyword == ";sig")
    }

    @Test func backspaceRemovesLast() {
        var b = TypingBuffer()
        b.apply(.characters("abc"))
        b.apply(.backspace)
        #expect(b.text == "ab")
        b.apply(.ignore)
        #expect(b.text == "ab")
        b.apply(.reset)
        #expect(b.text == "")
    }

    @Test func resetKeysClear() {
        let codes: [UInt16] = [36, 48, 49, 53, 123, 124, 125, 126, 117, 115, 119, 116, 121, 76,
                               122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for code in codes {
            #expect(KeyInput.classify(keyCode: code, characters: "a", flags: []) == .reset, "code \(code)")
        }
        #expect(KeyInput.classify(keyCode: 51, characters: "\u{7f}", flags: []) == .backspace)
    }

    @Test func commandOrControlResets() {
        #expect(KeyInput.classify(keyCode: 8, characters: "c", flags: .maskCommand) == .reset)
        #expect(KeyInput.classify(keyCode: 8, characters: "c", flags: .maskControl) == .reset)
        #expect(KeyInput.classify(keyCode: 0, characters: "A", flags: .maskShift) == .characters("A"))
    }

    @Test func optionCharacterAppends() {
        #expect(KeyInput.classify(keyCode: 14, characters: "é", flags: .maskAlternate) == .characters("é"))
    }

    @Test func deadKeyIgnored() {
        #expect(KeyInput.classify(keyCode: 14, characters: "", flags: []) == .ignore)
    }

    @Test func controlCharactersReset() {
        #expect(KeyInput.classify(keyCode: 14, characters: "\u{7}", flags: []) == .reset)
    }

    @Test func capacityKeepsTail() {
        var b = TypingBuffer()
        b.apply(.characters(String(repeating: "a", count: 199) + "z"))
        #expect(b.text.count == 128)
        #expect(b.text.hasSuffix("z"))
    }
}
