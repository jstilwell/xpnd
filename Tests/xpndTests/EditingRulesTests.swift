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

    /// Undo puts one back, so only a folder or group with things in it asks.
    @Test func deletingAConnectionOrSnippetDoesntAsk() {
        #expect(question(.connection(web.id), in: library()) == nil)
        #expect(question(.snippet(snippets.groups[0].snippets[0].id), in: library()) == nil)
    }

    /// The sidebar shows a nameless item as "Untitled", so the question does too, not "Delete “”?".
    @Test func deletingANamelessItemAsksAboutUntitled() {
        let library = library { $0.name = "" }
        #expect(question(.folder(library.folders[0].id), in: library)?.title == "Delete “Untitled” and everything in it?")
    }

    @Test func deletingAFolderAsksOnlyWhenItHoldsSomething() {
        let library = library()
        let q = question(.folder(library.folders[0].id), in: library)
        #expect(q?.title == "Delete “prod” and everything in it?")
        #expect(q?.message == "2 connections and 1 folder. You can undo this.")
        #expect(question(.folder(library.folders[1].id), in: library) == nil)
    }

    @Test func deletingAGroupAsksOnlyWhenItHoldsSomething() {
        let library = library()
        let work = question(.snippetGroup(snippets.groups[0].id), in: library)
        #expect(work?.title == "Delete “Work” and its 1 snippet?")
        #expect(work?.message == "You can undo this.")
        #expect(question(.snippetGroup(snippets.groups[1].id), in: library) == nil)
    }

    @Test func somethingAlreadyGoneHasNoQuestion() {
        #expect(question(.connection(UUID()), in: library()) == nil)
        #expect(question(.snippet(UUID()), in: library()) == nil)
    }
}
