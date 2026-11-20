import Foundation
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

    @Test func entriesAndTreeRowsCarryColors() {
        var lib = library()
        lib.folders[0].color = .yellow
        lib.folders[0].folders[0].connections[0].color = .red
        let entries = ConnectionFilter.entries(lib)
        #expect(entries.map(\.color) == [.yellow, .yellow, .red, nil])
        let rows = ConnectionTreeRow.rows(lib, expanded: Set(lib.allFolders.map(\.id)))
        #expect(rows.map(\.color) == [.yellow, .yellow, .yellow, .yellow, .red, nil, nil])
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

    @Test func filterFindsNotesWithTheFolderPath() {
        var noted = conn("zed")
        noted.notes = "Behind the office VPN"
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: [noted, conn("vpn-box")])])
        #expect(names(lib, "vpn") == ["vpn-box", "zed"])
    }

    @Test func recordingMovesToFrontPrunesAndCapsAtTen() {
        let ids = (0..<10).map { _ in UUID() }
        let existing = Set(ids)
        #expect(ConnectionFilter.recording(ids[3], in: ids, keeping: existing) == [ids[3]] + ids.filter { $0 != ids[3] })
        let new = UUID()
        let after = ConnectionFilter.recording(new, in: ids, keeping: existing.union([new]))
        #expect(after.count == 10 && after.first == new && !after.contains(ids[9]))
        #expect(ConnectionFilter.recording(new, in: ids, keeping: [new, ids[0]]) == [new, ids[0]])
    }

    @Test func shortlistSkipsFavoritesInRecentAndDropsDeleted() {
        var a = conn("a"), d = conn("d")
        a.favorite = true
        d.favorite = true
        let b = conn("b"), c = conn("c")
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: [d, a, b, c])])
        let list = ConnectionFilter.shortlist(ConnectionFilter.entries(lib), recents: [c.id, UUID(), a.id, b.id])
        #expect(list.favorites.map(\.connection.name) == ["d", "a"])
        #expect(list.recent.map(\.connection.name) == ["c", "b"])
    }

    @Test func shortlistShowsFiveRecent() {
        let all = (1...7).map { conn("c\($0)") }
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: all)])
        let list = ConnectionFilter.shortlist(ConnectionFilter.entries(lib), recents: all.reversed().map(\.id))
        #expect(list.recent.map(\.connection.name) == ["c7", "c6", "c5", "c4", "c3"])
        #expect(list.favorites.isEmpty)
    }

    @Test func queryTiesPreferFavoritesThenRecent() {
        var web3 = conn("web3")
        web3.favorite = true
        let web1 = conn("web1"), web2 = conn("web2"), web4 = conn("web4")
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: [web1, web2, web3, web4])])
        let found = ConnectionFilter.filter(ConnectionFilter.entries(lib), query: "web", recents: [web4.id, web2.id])
        #expect(found.map(\.connection.name) == ["web3", "web4", "web2", "web1"])
        #expect(names(lib, "web") == ["web3", "web1", "web2", "web4"]) // no recents: favorites still first
    }
}
