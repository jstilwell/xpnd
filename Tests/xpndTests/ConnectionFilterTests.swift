import Testing
@testable import xpnd

private func conn(_ name: String, host: String = "h.example.com", activation: String? = nil) -> Connection {
    Connection(name: name, host: host, activation: activation)
}

private func library() -> ConnectionLibrary {
    let web = ConnectionFolder(name: "web", connections: [conn("nginx")])
    let prod = ConnectionFolder(name: "Prod", connections: [conn("db"), conn("api")], folders: [web])
    let dev = ConnectionFolder(name: "dev", connections: [conn("sandbox")])
    return ConnectionLibrary(folders: [prod, dev])
}

struct ConnectionFilterTests {
    private func names(_ lib: ConnectionLibrary, _ query: String) -> [String] {
        ConnectionFilter.filter(ConnectionFilter.entries(lib), query: query).map(\.connection.name)
    }

    @Test func treeOrderWhenEmpty() {
        let entries = ConnectionFilter.entries(library())
        #expect(entries.map(\.connection.name) == ["db", "api", "nginx", "sandbox"])
        #expect(entries[2].path == ["Prod", "web"])
        #expect(entries[2].pathText == "Prod › web")
        #expect(names(library(), "") == ["db", "api", "nginx", "sandbox"])
    }

    @Test func rankNamePrefixFirst() {
        let folder = ConnectionFolder(name: "zzz", connections: [
            conn("b-box", host: "x.example.com"), conn("zeta", host: "web.example.com"),
            conn("a-web", host: "x.example.com"), conn("m", activation: ";web"), conn("webby"),
        ], folders: [ConnectionFolder(name: "web", connections: [conn("inner")])])
        // webby: name prefix; a-web, m, zeta: contains (by name); inner: folder path.
        #expect(names(ConnectionLibrary(folders: [folder]), "web") == ["webby", "a-web", "m", "zeta", "inner"])
    }

    @Test func matchesFolderPath() {
        #expect(names(library(), "prod") == ["api", "db", "nginx"])
    }

    @Test func caseAndDiacriticInsensitive() {
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "F", connections: [conn("Café")])])
        #expect(names(lib, "CAFE") == ["Café"])
    }

    @Test func treeRows() {
        let lib = library()
        let prod = lib.folders[0], web = prod.folders[0]
        let all = Set(lib.allFolders.map(\.id))
        let rows = ConnectionTreeRow.rows(lib, expanded: all)
        #expect(rows.map(\.title) == ["Prod", "db", "api", "web", "nginx", "dev", "sandbox"])
        #expect(rows.map(\.depth) == [0, 1, 1, 1, 2, 0, 1])
        #expect(ConnectionTreeRow.rows(lib, expanded: [prod.id]).map(\.title) == ["Prod", "db", "api", "web", "dev"])
        #expect(ConnectionTreeRow.rows(lib, expanded: [prod.id, web.id]).count == 6)
        let rows2 = ConnectionTreeRow.rows(lib, expanded: all)
        #expect(ConnectionTreeRow.parent(of: 4, in: rows2) == 3)
        #expect(ConnectionTreeRow.parent(of: 3, in: rows2) == 0)
        #expect(ConnectionTreeRow.parent(of: 0, in: rows2) == nil)
    }
}
