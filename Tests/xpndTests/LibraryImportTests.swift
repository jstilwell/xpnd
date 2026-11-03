import Testing
@testable import xpnd

private func snip(_ keyword: String, _ text: String = "t") -> Snippet {
    Snippet(name: "n" + keyword, keyword: keyword, text: text)
}

private func lib(_ groups: (String, [Snippet])...) -> SnippetLibrary {
    SnippetLibrary(groups: groups.map { SnippetGroup(name: $0.0, snippets: $0.1) })
}

@Test func sameNamedGroupsMerge() {
    let out = LibraryImport.merge(lib(("Work", [snip(";b")])), into: lib(("Work", [snip(";a")])), choice: .skip)
    #expect(out.groups.map(\.name) == ["Work"])
    #expect(out.groups[0].snippets.map(\.keyword) == [";a", ";b"])
}

@Test func newGroupIsAdded() {
    let out = LibraryImport.merge(lib(("Home", [snip(";b")])), into: lib(("Work", [snip(";a")])), choice: .skip)
    #expect(out.groups.map(\.name) == ["Work", "Home"])
}

@Test func skipKeepsExisting() {
    let out = LibraryImport.merge(lib(("Work", [snip(";a", "new")])), into: lib(("Work", [snip(";a", "old")])), choice: .skip)
    #expect(out.groups[0].snippets.map(\.text) == ["old"])
}

@Test func replaceMovesToIncomingGroup() {
    let out = LibraryImport.merge(lib(("Work", [snip(";a", "new")])), into: lib(("Home", [snip(";a", "old")])), choice: .replace)
    #expect(out.groups.first { $0.name == "Home" }?.snippets.isEmpty == true)
    #expect(out.groups.first { $0.name == "Work" }?.snippets.map(\.text) == ["new"])
}

@Test func conflictsListed() {
    let c = LibraryImport.conflicts(incoming: lib(("Work", [snip(";a"), snip(";z")])), existing: lib(("Home", [snip(";a")])))
    #expect(c == [";a"])
}

@Test func riskyActionsFound() {
    let l = lib(("Work", [
        snip(";s", "run #{shell:/x.sh:500} now"),
        snip(";o", "#{openApp:/A.app}"),
        snip(";r", "#{runShortcut:Foo}"),
        snip(";p", "plain #{date}"),
    ]))
    let r = LibraryImport.riskyActions(in: l)
    #expect(r.map(\.target) == ["/x.sh", "/A.app", "Foo"])
    #expect(r.map(\.keyword) == [";s", ";o", ";r"])
}

@Test func exportSelectedGroupsRoundTrips() throws {
    let l = lib(("Work", [snip(";a")]), ("Home", [snip(";b")]))
    let yaml = LibraryImport.export(l, groups: [l.groups[0].id])
    let back = try SnippetYAML.decode(yaml)
    #expect(back.groups.map(\.name) == ["Work"])
    #expect(LibraryImport.export(l, groups: nil) == SnippetYAML.encode(l))
}
