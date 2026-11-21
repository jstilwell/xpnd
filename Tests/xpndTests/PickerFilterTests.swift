import Testing
@testable import xpnd

private func snip(_ name: String, _ keyword: String = "k", text: String = "t", enabled: Bool = true) -> Snippet {
    Snippet(name: name, keyword: keyword, enabled: enabled, text: text)
}

struct PickerFilterTests {
    @Test func emptyQueryListsActiveByName() {
        let result = PickerFilter.filter([snip("b"), snip("a")], query: "")
        #expect(result.map(\.name) == ["a", "b"])
    }

    @Test func keywordPrefixRanksFirst() {
        let result = PickerFilter.filter([snip("Design", "x"), snip("Zed", "sig")], query: "sig")
        #expect(result.map(\.name) == ["Zed", "Design"])
    }

    @Test func caseAndDiacriticInsensitive() {
        #expect(PickerFilter.filter([snip("Café")], query: "CAFE").map(\.name) == ["Café"])
    }

    @Test func searchesText() {
        let result = PickerFilter.filter([snip("A", text: "has needle"), snip("Z", "needle")], query: "needle")
        #expect(result.map(\.name) == ["Z", "A"])
    }

    @Test func disabledExcluded() {
        let library = SnippetLibrary(groups: [
            SnippetGroup(name: "on", snippets: [snip("a"), snip("b", enabled: false)]),
            SnippetGroup(name: "off", enabled: false, snippets: [snip("c")]),
        ])
        // filter takes snippets as given; the caller passes `activeSnippets`.
        #expect(PickerFilter.filter(library.activeSnippets, query: "").map(\.name) == ["a"])
    }

    @Test func groupNamesForEachSnippet() {
        let a = snip("a"), b = snip("b")
        let library = SnippetLibrary(groups: [SnippetGroup(name: "Work", snippets: [a]), SnippetGroup(name: "", snippets: [b])])
        #expect(PickerFilter.groupNames(library) == [a.id: "Work", b.id: "Untitled"])
    }
}
