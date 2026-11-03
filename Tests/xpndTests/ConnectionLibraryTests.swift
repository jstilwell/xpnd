import Testing
@testable import xpnd

private func ref(_ item: String, _ category: CredentialCategory = .login) -> CredentialRef {
    CredentialRef(account: "acct", vault: "vault", item: item, title: item, category: category)
}

private func server(_ name: String, credential: CredentialRef? = nil, sudo: CredentialRef? = nil) -> Connection {
    Connection(name: name, host: "\(name).example.com", credential: credential, sudoCredential: sudo)
}

@Suite struct ConnectionLibraryTests {
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
}
