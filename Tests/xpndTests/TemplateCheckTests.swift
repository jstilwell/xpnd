import Foundation
import Testing
@testable import xpnd

struct TemplateCheckTests {
    private let library = SnippetLibrary(groups: [SnippetGroup(name: "G", snippets: [
        Snippet(name: "sig", keyword: ";sig", text: "Best"),
    ])])

    @Test func marksGoodAndBadVariables() {
        let marks = TemplateCheck.marks(in: "a #{date} #{key:tabb} #{nope}", keyword: ";t", library: library)
        #expect(marks == [
            TemplateMark(range: NSRange(location: 2, length: 7), problem: nil),
            TemplateMark(range: NSRange(location: 10, length: 11), problem: "“tabb” isn't a key name."),
            TemplateMark(range: NSRange(location: 22, length: 7), problem: "xpnd has no variable “#{nope}”."),
        ])
    }

    @Test func marksMissingAndSelfIncludingSnippets() {
        let marks = TemplateCheck.marks(in: "#{combo:;sig}#{upper:;zz}#{lower:;t}", keyword: ";t", library: library)
        #expect(marks.map(\.problem) == [nil, "No snippet has the keyword “;zz”.", "This snippet can't include itself."])
    }

    @Test func plainTextHasNoMarks() {
        #expect(TemplateCheck.marks(in: "#{ not a variable", keyword: ";t", library: library).isEmpty)
    }
}
