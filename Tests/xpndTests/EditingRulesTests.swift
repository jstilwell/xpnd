import AppKit
import Testing
@testable import xpnd

@MainActor struct EditingRulesTests {
    private let web = Connection(name: "web", host: "web.example")
    private let db = Connection(name: "db", host: "db.example")
    private var inner: ConnectionFolder { ConnectionFolder(name: "inner", connections: [db]) }

    /// prod: web, inner: db
    private func library(_ change: (inout ConnectionFolder) -> Void = { _ in }) -> ConnectionLibrary {
        var prod = ConnectionFolder(name: "prod", connections: [web], folders: [inner])
        change(&prod)
        return ConnectionLibrary(folders: [prod, ConnectionFolder(name: "empty")])
    }

    private let snippets = SnippetLibrary(groups: [
        SnippetGroup(name: "Work", snippets: [Snippet(name: "Sig", keyword: ";sig", text: "Regards")]),
        SnippetGroup(name: "Spare", snippets: []),
    ])

    // MARK: Showing a selection the tree hides

    @Test func aSelectedConnectionOpensEveryFolderAboveIt() {
        let library = library()
        let prod = library.folders[0], inner = prod.folders[0]
        #expect(EditorRules.foldersToOpen(for: .connection(db.id), in: library) == [prod.id, inner.id])
        #expect(EditorRules.foldersToOpen(for: .connection(web.id), in: library) == [prod.id])
    }

    @Test func aSelectedFolderOpensItsAncestorsButNotItself() {
        let library = library()
        let prod = library.folders[0], inner = prod.folders[0]
        #expect(EditorRules.foldersToOpen(for: .folder(inner.id), in: library) == [prod.id])
        #expect(EditorRules.foldersToOpen(for: .folder(prod.id), in: library).isEmpty)
    }

    @Test func nothingElseOpensAFolder() {
        let library = library()
        #expect(EditorRules.foldersToOpen(for: nil, in: library).isEmpty)
        #expect(EditorRules.foldersToOpen(for: .snippet(UUID()), in: library).isEmpty)
        #expect(EditorRules.foldersToOpen(for: .connection(UUID()), in: library).isEmpty)
    }

    // MARK: Asking before a delete

    private func question(_ item: SidebarItem, in library: ConnectionLibrary) -> (title: String, message: String)? {
        EditorRules.deleteQuestion(for: item, connections: library, snippets: snippets)
    }

    @Test func deletingAConnectionAsks() {
        let q = question(.connection(web.id), in: library())
        #expect(q?.title == "Delete “web”?")
        #expect(q?.message == "This can't be undone.")
    }

    @Test func deletingAJumpHostSaysWhoUsesIt() {
        let library = library { $0.folders[0].connections[0].jumpHost = .connection(web.id) }
        #expect(question(.connection(web.id), in: library)?.message == "1 connection uses it as a jump host and will lose it. This can't be undone.")
    }

    @Test func deletingAFolderAsksOnlyWhenItHoldsSomething() {
        let library = library()
        let q = question(.folder(library.folders[0].id), in: library)
        #expect(q?.title == "Delete “prod” and everything in it?")
        #expect(q?.message == "2 connections and 1 folder. This can't be undone.")
        #expect(question(.folder(library.folders[1].id), in: library) == nil)
    }

    @Test func deletingASnippetAsksAndAGroupOnlyWhenItHoldsSomething() {
        let library = library()
        let sig = question(.snippet(snippets.groups[0].snippets[0].id), in: library)
        #expect(sig?.title == "Delete “Sig”?")
        #expect(sig?.message == "Its keyword is ;sig. This can't be undone.")
        let work = question(.snippetGroup(snippets.groups[0].id), in: library)
        #expect(work?.title == "Delete “Work” and its 1 snippet?")
        #expect(question(.snippetGroup(snippets.groups[1].id), in: library) == nil)
    }

    @Test func somethingAlreadyGoneHasNoQuestion() {
        #expect(question(.connection(UUID()), in: library()) == nil)
        #expect(question(.snippet(UUID()), in: library()) == nil)
    }
}
