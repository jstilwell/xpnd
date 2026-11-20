import CoreGraphics
import Testing
@testable import xpnd

@Suite struct TypingTests {
    private func snip(_ keyword: String, _ mode: MatchingMode) -> Snippet {
        Snippet(name: keyword, keyword: keyword, matching: mode, text: "x")
    }

    @Test func instantMatchesLooseSuffixOnly() {
        #expect(Matcher.instant("First==>", in: [snip("==>", .loose)])?.keyword == "==>")
        #expect(Matcher.instant(";sig", in: [snip(";sig", .strict)]) == nil)
    }

    @Test func instantLongestWins() {
        let s = [snip("ig", .loose), snip("sig", .loose)]
        #expect(Matcher.instant(";sig", in: s)?.keyword == "sig")
    }

    @Test func strictFiresOnSpaceOrPunctuation() {
        let s = [snip(";sig", .strict)]
        #expect(Matcher.strict(word: ";sig", boundary: " ", in: s)?.keyword == ";sig")
        #expect(Matcher.strict(word: ";sig", boundary: ".", in: s)?.keyword == ";sig")
        #expect(Matcher.strict(word: ";sig", boundary: "a", in: s) == nil)
    }

    @Test func strictNeedsTheWholeWord() {
        let s = [snip(";sig", .strict)]
        #expect(Matcher.strict(word: "x;sig", boundary: " ", in: s) == nil)
    }

    @Test func strictWordMayStartAfterOpeningCharacters() {
        let s = [snip(";sig", .strict)]
        #expect(Matcher.strict(word: "(;sig", boundary: " ", in: s)?.keyword == ";sig")
        #expect(Matcher.strict(word: "\"(;sig", boundary: " ", in: s)?.keyword == ";sig")
        // Letters before the opening character: it's inside a word.
        #expect(Matcher.strict(word: "don't", boundary: " ", in: [snip("t", .strict)]) == nil)
    }

    @Test func strictYieldsToALongerKeywordThatContinuesWithTheBoundary() {
        let s = [snip(";sig", .strict), snip(";sig.", .strict)]
        #expect(Matcher.strict(word: ";sig", boundary: ".", in: s) == nil)
        #expect(Matcher.strict(word: ";sig.", boundary: " ", in: s)?.keyword == ";sig.")
    }

    @Test func strictIgnoresLooseSnippets() {
        #expect(Matcher.strict(word: ";sig", boundary: " ", in: [snip(";sig", .loose)]) == nil)
    }

    @Test func spaceIsABoundaryThatResets() {
        #expect(KeyInput.classify(keyCode: 49, characters: " ", flags: []) == .boundary(" "))
        #expect(KeyInput.classify(keyCode: 49, characters: " ", flags: .maskCommand) == .reset)
        var b = TypingBuffer()
        b.apply(.characters(";sig"))
        b.apply(.boundary(" "))
        #expect(b.text == "")
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
        let codes: [UInt16] = [36, 48, 53, 123, 124, 125, 126, 117, 115, 119, 116, 121, 76,
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

    @Test func optionDeleteResets() {
        #expect(KeyInput.classify(keyCode: 51, characters: "\u{7f}", flags: .maskAlternate) == .reset)
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
