import Testing
@testable import xpnd

private let signature = Snippet(name: "Signature", keyword: ";sig", text: "Jesse")
private let library = SnippetLibrary(groups: [SnippetGroup(name: "Work", snippets: [signature])])

@Test func emptyKeyword() {
    #expect(library.keywordProblem("", for: nil) == "Keyword can't be empty")
}

@Test func keywordWithSpace() {
    #expect(library.keywordProblem(";a b", for: nil) == "Keywords can't contain spaces or tabs")
    #expect(library.keywordProblem(";a\tb", for: nil) == "Keywords can't contain spaces or tabs")
}

@Test func duplicateNamesOwner() {
    #expect(library.keywordProblem(";sig", for: nil) == "“;sig” is already used by “Signature”")
}

@Test func sameSnippetIsFine() {
    #expect(library.keywordProblem(";sig", for: signature.id) == nil)
}

@Test func tooLong() {
    #expect(library.keywordProblem(String(repeating: "a", count: 129), for: nil) == "Keywords can be at most 128 characters")
    #expect(library.keywordProblem(String(repeating: "a", count: 128), for: nil) == nil)
}
