import Foundation
import Testing
@testable import xpnd

private func ref(_ item: String, _ category: CredentialCategory = .login) -> CredentialRef {
    CredentialRef(account: "acct", vault: "vault", item: item, title: item, category: category)
}

private func server(_ name: String, credential: CredentialRef? = nil, sudo: CredentialRef? = nil) -> Connection {
    Connection(name: name, host: "\(name).example.com", credential: credential, sudoCredential: sudo)
}

@Suite struct ConnectionLibraryTests {
    @Test func colorCascade() {
        let own = Connection(name: "own", host: "h", color: .red)
        let fromLan = Connection(name: "lan-box", host: "h")
        let plain = Connection(name: "plain", host: "h")
        let inner = ConnectionFolder(name: "inner", connections: [fromLan])
        let lan = ConnectionFolder(name: "lan", connections: [own], folders: [inner], color: .blue)
        let dev = ConnectionFolder(name: "dev", connections: [plain])
        let library = ConnectionLibrary(folders: [lan, dev])

        #expect(library.color(for: .connection(own.id)) == ResolvedColor(color: .red, inheritedFrom: nil))
        // The nearest colored folder, by name, so the editor can say where it came from.
        #expect(library.color(for: .connection(fromLan.id)) == ResolvedColor(color: .blue, inheritedFrom: "lan"))
        #expect(library.color(for: .folder(inner.id)) == ResolvedColor(color: .blue, inheritedFrom: "lan"))
        #expect(library.color(for: .folder(lan.id)) == ResolvedColor(color: .blue, inheritedFrom: nil))
        #expect(library.color(for: .connection(plain.id)) == nil)
        #expect(library.color(for: .connection(UUID())) == nil)
    }

    @Test func loginCascade() {
        let override = server("override", credential: ref("O"))
        let nearest = server("nearest")
        let ancestor = server("ancestor")
        let top = server("top")
        let global = server("global")
        let aws = ConnectionFolder(name: "aws", credential: ref("A"), connections: [override, nearest])
        let misc = ConnectionFolder(name: "misc", connections: [ancestor])
        let prod = ConnectionFolder(name: "prod", credential: ref("P"), connections: [top], folders: [aws, misc])
        let other = ConnectionFolder(name: "other", connections: [global])
        var library = ConnectionLibrary(credential: ref("G"), folders: [prod, other])

        #expect(library.loginCredential(for: override.id) == ResolvedCredential(ref: ref("O"), source: .connection))
        #expect(library.loginCredential(for: nearest.id) == ResolvedCredential(ref: ref("A"), source: .folder(name: "aws")))
        #expect(library.loginCredential(for: top.id) == ResolvedCredential(ref: ref("P"), source: .folder(name: "prod")))
        #expect(library.loginCredential(for: ancestor.id) == ResolvedCredential(ref: ref("P"), source: .folder(name: "prod")))
        #expect(library.loginCredential(for: global.id) == ResolvedCredential(ref: ref("G"), source: .global))
        library.credential = nil
        #expect(library.loginCredential(for: global.id) == nil)
        #expect(library.loginCredential(for: Connection.ID()) == nil)
    }

    @Test func sudoStopsFallingBackToLoginWhenOff() {
        let own = server("own", sudo: ref("CS", .password))
        let plain = server("plain")
        let team = ConnectionFolder(name: "team", sudoCredential: ref("TS", .password), connections: [plain])
        let bare = server("bare")
        var library = ConnectionLibrary(credential: ref("pw", .login), folders: [team, ConnectionFolder(name: "o", connections: [own, bare])])

        #expect(library.sudoUsesLogin)
        #expect(library.sudoCredential(for: bare.id) == ResolvedCredential(ref: ref("pw", .login), source: .login))
        library.sudoUsesLogin = false
        #expect(library.sudoCredential(for: bare.id) == nil)
        #expect(library.sudoCredential(for: own.id) == ResolvedCredential(ref: ref("CS", .password), source: .connection))
        #expect(library.sudoCredential(for: plain.id) == ResolvedCredential(ref: ref("TS", .password), source: .folder(name: "team")))
        library.sudoCredential = ref("GS", .password)
        #expect(library.sudoCredential(for: bare.id) == ResolvedCredential(ref: ref("GS", .password), source: .global))
    }

    @Test func sudoCascade() {
        let own = server("own", sudo: ref("CS", .password))
        let shared = server("shared")
        let plain = server("plain")
        let team = ConnectionFolder(name: "team", sudoCredential: ref("TS", .password), connections: [own, shared])
        let other = ConnectionFolder(name: "other", connections: [plain])
        var library = ConnectionLibrary(credential: ref("key", .sshKey), sudoCredential: ref("GS", .password), folders: [team, other])

        #expect(library.sudoCredential(for: own.id) == ResolvedCredential(ref: ref("CS", .password), source: .connection))
        #expect(library.sudoCredential(for: shared.id) == ResolvedCredential(ref: ref("TS", .password), source: .folder(name: "team")))
        #expect(library.sudoCredential(for: plain.id) == ResolvedCredential(ref: ref("GS", .password), source: .global))
        library.sudoCredential = nil
        // A key-only login has no password to fall back to.
        #expect(library.sudoCredential(for: plain.id) == nil)
        library.credential = ref("pw", .login)
        #expect(library.sudoCredential(for: plain.id) == ResolvedCredential(ref: ref("pw", .login), source: .login))
    }

    @Test func treeOrder() {
        let a1 = server("a1"), a2 = server("a2"), b1 = server("b1"), c1 = server("c1")
        let b = ConnectionFolder(name: "B", connections: [b1])
        let a = ConnectionFolder(name: "A", connections: [a1, a2], folders: [b])
        let c = ConnectionFolder(name: "C", connections: [c1])
        let library = ConnectionLibrary(folders: [a, c])

        #expect(library.allConnections.map(\.name) == ["a1", "a2", "b1", "c1"])
        #expect(library.connection(b1.id) == b1)
        #expect(library.connection(Connection.ID()) == nil)
        #expect(library.folder(b.id) == b)
        #expect(library.folder(ConnectionFolder.ID()) == nil)
    }

    @Test func pathOfNested() {
        let deep = server("deep"), shallow = server("shallow")
        let inner = ConnectionFolder(name: "inner", connections: [deep])
        let outer = ConnectionFolder(name: "outer", connections: [shallow], folders: [inner])
        let library = ConnectionLibrary(folders: [ConnectionFolder(name: "first"), outer])

        #expect(library.path(of: deep.id).map(\.name) == ["outer", "inner"])
        #expect(library.path(of: shallow.id).map(\.name) == ["outer"])
        #expect(library.path(of: Connection.ID()).isEmpty)
    }

    // MARK: Putting an item back (undo)

    private func undoLibrary() -> (ConnectionLibrary, Connection, Connection, ConnectionFolder) {
        let a = Connection(name: "a", host: "a"), b = Connection(name: "b", host: "b")
        let web = ConnectionFolder(name: "web")
        return (ConnectionLibrary(folders: [ConnectionFolder(name: "prod", connections: [a, b], folders: [web]), ConnectionFolder(name: "dev")]), a, b, web)
    }

    @Test func restoreAConnectionAtItsPlace() throws {
        var (library, a, b, _) = undoLibrary()
        let place = try #require(library.placement(of: .connection(a.id)))
        let taken = library.remove(.connection(a.id))
        let removed = try #require(taken)
        library.editConnection(b.id) { $0.host = "edited" } // a later edit survives
        let ok1 = library.restore(removed, at: place)
        #expect(ok1)
        #expect(library.folders[0].connections.map(\.name) == ["a", "b"])
        #expect(library.connection(b.id)?.host == "edited")
    }

    @Test func restoreIntoAGoneFolderMakesOne() throws {
        var (library, a, _, _) = undoLibrary()
        let place = try #require(library.placement(of: .connection(a.id)))
        let taken = library.remove(.connection(a.id))
        let removed = try #require(taken)
        library.folders.removeFirst()
        let ok2 = library.restore(removed, at: place)
        #expect(ok2)
        #expect(library.folders.map(\.name) == ["dev", "prod"])
        #expect(library.folders.last?.connections.map(\.id) == [a.id])
    }

    @Test func restoreAFolderAtItsPlaceOrTheTopLevel() throws {
        var (library, _, _, web) = undoLibrary()
        let place = try #require(library.placement(of: .folder(web.id)))
        #expect(place.parent == library.folders[0].id && place.index == 0)
        let taken = library.remove(.folder(web.id))
        let removed = try #require(taken)
        var copy = library
        let ok3 = copy.restore(removed, at: place)
        #expect(ok3)
        #expect(copy.folders[0].folders.map(\.id) == [web.id])
        library.folders.removeFirst()
        let ok4 = library.restore(removed, at: place)
        #expect(ok4)
        #expect(library.folders.map(\.name) == ["dev", "web"])
    }

    @Test func restoreRefusesAnIDAlreadyThere() throws {
        var (library, a, _, _) = undoLibrary()
        let place = try #require(library.placement(of: .connection(a.id)))
        let ok5 = library.restore(.connection(a), at: place)
        #expect(!ok5)
        #expect(library.allConnections.count == 2)
    }

    @Test func moveBackReturnsToTheOldPosition() throws {
        var (library, a, b, web) = undoLibrary()
        let place = try #require(library.placement(of: .connection(a.id)))
        library.move(.connection(a.id), to: library.folders[0].id, at: 2) // reorder: now b, a
        #expect(library.folders[0].connections.map(\.id) == [b.id, a.id])
        let ok6 = library.moveBack(.connection(a.id), to: place)
        #expect(ok6)
        #expect(library.folders[0].connections.map(\.id) == [a.id, b.id])
        library.move(.connection(a.id), to: web.id)
        let ok7 = library.moveBack(.connection(a.id), to: place)
        #expect(ok7)
        #expect(library.folders[0].connections.map(\.id) == [a.id, b.id])
        #expect(library.folder(web.id)?.connections.isEmpty == true)
    }

    @Test func moveBackWithTheOldFolderGoneLeavesIt() throws {
        var (library, a, _, web) = undoLibrary()
        let place = ConnectionPlacement(parent: UUID(), parentName: "gone", index: 0)
        library.move(.connection(a.id), to: web.id)
        let ok8 = library.moveBack(.connection(a.id), to: place)
        #expect(!ok8)
        #expect(library.folder(web.id)?.connections.map(\.id) == [a.id])
    }
}
