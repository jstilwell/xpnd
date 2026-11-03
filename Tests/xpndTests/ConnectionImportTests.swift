import Foundation
import Testing
@testable import xpnd

private func conn(_ name: String, host: String = "h", act: String? = nil, jump: JumpHost? = nil, id: UUID = UUID()) -> Connection {
    Connection(id: id, name: name, host: host, activation: act, jumpHost: jump)
}

struct ConnectionImportTests {
    @Test func mergeByFolderName() {
        let existing = ConnectionLibrary(folders: [ConnectionFolder(
            name: "prod", connections: [conn("a")], folders: [ConnectionFolder(name: "db", connections: [conn("d1")])])])
        let incoming = ConnectionLibrary(folders: [
            ConnectionFolder(name: "prod", connections: [conn("b")],
                             folders: [ConnectionFolder(name: "db", connections: [conn("d2")])]),
            ConnectionFolder(name: "new", connections: [conn("n")])])
        let r = ConnectionImport.merge(incoming, into: existing, choice: .skip)
        #expect(r.folders.map(\.name) == ["prod", "new"])
        #expect(r.folders[0].connections.map(\.name) == ["a", "b"])
        #expect(r.folders[0].folders.count == 1)
        #expect(r.folders[0].folders[0].connections.map(\.name) == ["d1", "d2"])
    }

    @Test func skipReplaceOnActivationConflict() {
        let old = conn("old", act: ";x")
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [old])])
        let incoming = ConnectionLibrary(folders: [
            ConnectionFolder(name: "b", activation: ";f", connections: [conn("new", act: ";x")])])
        #expect(ConnectionImport.conflicts(incoming: incoming, existing: existing) == [";x"])

        let skipped = ConnectionImport.merge(incoming, into: existing, choice: .skip)
        #expect(skipped.allConnections.map(\.name) == ["old"])
        #expect(skipped.folders.map(\.name) == ["a", "b"])

        let replaced = ConnectionImport.merge(incoming, into: existing, choice: .replace)
        #expect(replaced.folders[0].connections.isEmpty)
        #expect(replaced.folders[1].connections.map(\.name) == ["new"])

        // A conflicting folder string is cleared to nil under skip.
        let existingF = ConnectionLibrary(folders: [ConnectionFolder(name: "z", activation: ";f")])
        let s = ConnectionImport.merge(incoming, into: existingF, choice: .skip)
        #expect(s.folders[1].activation == nil)
        let r = ConnectionImport.merge(incoming, into: existingF, choice: .replace)
        #expect(r.folders[1].activation == ";f")
        #expect(r.folders[0].activation == "")
    }

    @Test func idsKeptUnlessColliding() {
        let shared = conn("shared")
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [shared])])
        let keep = conn("keep")
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "b", connections: [
            conn("shared2", id: shared.id), conn("viaJump", jump: .connection(shared.id)), keep])])
        let r = ConnectionImport.merge(incoming, into: existing, choice: .skip)
        let b = r.folders[1].connections
        #expect(b[0].id != shared.id)
        #expect(b[1].jumpHost == .connection(b[0].id))
        #expect(b[2].id == keep.id)
        #expect(Set(r.allConnections.map(\.id)).count == 4)
    }

    @Test func hostsAddedListed() {
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [conn("x", host: "old")])])
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [
            conn("1", host: "zeta"), conn("2", host: "alpha"), conn("3", host: "alpha")])])
        #expect(ConnectionImport.hostsAdded(incoming: incoming, existing: existing) == ["alpha", "zeta"])
    }

    @Test func exportSelectedFoldersRoundTrips() throws {
        let inner = ConnectionFolder(name: "inner", connections: [conn("i", jump: .text("j"))])
        let a = ConnectionFolder(name: "a", activation: ";a", connections: [conn("c")], folders: [inner])
        let b = ConnectionFolder(name: "b", connections: [conn("d")])
        let lib = ConnectionLibrary(folders: [a, b])
        let one = try ConnectionYAML.decode(ConnectionImport.export(lib, folders: [a.id]))
        #expect(one.folders == [a])
        let nested = try ConnectionYAML.decode(ConnectionImport.export(lib, folders: [inner.id]))
        #expect(nested.folders == [inner])
        #expect(try ConnectionYAML.decode(ConnectionImport.export(lib, folders: nil)) == lib)
    }
}
