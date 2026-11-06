import Foundation
import Testing
@testable import xpnd

private func ref(_ item: String, _ category: CredentialCategory = .login) -> CredentialRef {
    CredentialRef(account: "acct", vault: "vault", item: item, title: item, category: category)
}

/// `publicKey` waits for `release`, like an unanswered Touch ID prompt.
@MainActor private final class HeldKeyProvider: CredentialProvider {
    private var gate: CheckedContinuation<Void, Never>?
    var isHolding: Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }

    func status(account: String?) async -> ProviderStatus { .notInstalled }
    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem] { [] }
    func password(for ref: CredentialRef) async throws(CredentialError) -> String { throw .locked }
    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String {
        await withCheckedContinuation { gate = $0 }
        return "ssh-ed25519 AAAA test\n"
    }
}

/// Two signed-in accounts.
private struct TwoAccountProvider: CredentialProvider {
    func status(account: String?) async -> ProviderStatus {
        let accounts = [ProviderAccount(id: "A1", email: "a@x", url: "x"), ProviderAccount(id: "A2", email: "b@x", url: "x")]
        return accounts.contains { $0.id == account } ? .ready(accounts) : .chooseAccount(accounts)
    }
    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem] { [] }
    func password(for ref: CredentialRef) async throws(CredentialError) -> String { throw .locked }
    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String { throw .locked }
}

@MainActor private func editing(_ provider: any CredentialProvider, account: String? = nil) -> (ConnectionEditing, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let editing = ConnectionEditing(
        store: ConnectionStore(fileURL: directory.appending(path: "connections.yaml")),
        snippets: SnippetStore(fileURL: directory.appending(path: "snippets.yaml")),
        provider: { provider }, preferredAccount: { account }, keysDirectory: directory.appending(path: "keys"),
        connect: { _, _ in })
    return (editing, directory)
}

@Suite struct MainWindowLogicTests {
    @MainActor @Test func aSavedDisplayLandsInTheConnectionsRDPOptions() throws {
        let (editing, _) = editing(TwoAccountProvider())
        let folder = try #require(editing.addFolder(in: nil))
        let id = try #require(editing.addConnection(in: folder))
        let size = RDPOptions.Display.fixed(width: 1920, height: 1080)
        #expect(editing.saveDisplay(id, size))
        #expect(editing.library.connection(id)?.rdp?.display == size)
    }

    @MainActor @Test func savingADisplayForAGoneConnectionDoesNothing() {
        let (editing, _) = editing(TwoAccountProvider())
        let before = editing.library
        #expect(!editing.saveDisplay(UUID(), .fit))
        #expect(editing.library == before)
        #expect(editing.saveProblem == nil)
    }

    @MainActor @Test func accountIsTheSettingOrAsksForOne() async throws {
        #expect(try await editing(TwoAccountProvider(), account: "A2").0.account() == "A2")
        // With two accounts, no choice (or a stale one) never silently picks the first.
        for account in [nil, "gone"] {
            await #expect(throws: CredentialError.failed("Choose your 1Password account in Settings → Password Manager.")) {
                try await editing(TwoAccountProvider(), account: account).0.account()
            }
        }
    }

    @MainActor @Test func cancelledPickIsNeverStored() async throws {
        let provider = HeldKeyProvider()
        let (editing, directory) = editing(provider)
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = CredentialItem(id: "key1", vaultID: "v1", vaultName: "Private", title: "deploy", category: .sshKey, username: nil)

        let cancelled = Task { try await editing.pick(item, account: "acct") }
        while !provider.isHolding { await Task.yield() }
        cancelled.cancel()
        provider.release()
        #expect(try await cancelled.value == nil)

        let kept = Task { try await editing.pick(item, account: "acct") }
        while !provider.isHolding { await Task.yield() }
        provider.release()
        #expect(try await kept.value == item.ref(account: "acct"))
        let key = try String(contentsOf: directory.appending(path: "keys/key1.pub"), encoding: .utf8)
        #expect(key == "ssh-ed25519 AAAA test\n")
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "keys/key1.pub").path)[.posixPermissions] as? Int
        #expect(mode == 0o644)
    }

    @MainActor @Test func unsafePickIsRefused() async {
        let (editing, directory) = editing(HeldKeyProvider())
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = CredentialItem(id: "../evil", vaultID: "v1", vaultName: "Private", title: "x", category: .sshKey, username: nil)
        await #expect(throws: CredentialError.invalidRef) { try await editing.pick(item, account: "acct") }
    }

    /// The default ";new" mustn't take a string a connection already owns.
    @MainActor @Test func newSnippetKeywordSkipsConnectionStrings() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editing = SnippetEditing(store: SnippetStore(fileURL: directory.appending(path: "snippets.yaml")))
        let groupID = try #require(editing.addGroup())
        let group = try #require(editing.group(groupID))
        let connections = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: [Connection(name: "c", host: "h", activation: ";new")])])
        let id = try #require(editing.addSnippet(to: group, connections: connections))
        #expect(editing.snippet(id)?.keyword == ";new2")
    }

    @Test func addTargetFollowsTheSelection() {
        let web = Connection(name: "web", host: "h")
        let inner = ConnectionFolder(name: "inner", connections: [web])
        let dev = ConnectionFolder(name: "dev", folders: [inner])
        let library = ConnectionLibrary(folders: [dev])
        #expect(EditorRules.addTarget(for: nil, in: library) == nil)
        #expect(EditorRules.addTarget(for: .folder(inner.id), in: library) == inner.id)
        // A selected connection adds beside it, in its own folder.
        #expect(EditorRules.addTarget(for: .connection(web.id), in: library) == inner.id)
        #expect(EditorRules.addTarget(for: .snippet(UUID()), in: library) == nil)
        #expect(EditorRules.addTarget(for: .folder(UUID()), in: library) == nil)
    }

    @Test func aboveTheLineIsTheRowAbove() {
        let a = UUID(), b = UUID(), c = UUID(), container = UUID()
        // A drop between rows reports the index of the row below the line.
        #expect(EditorRules.aboveTheLine(index: 1, siblings: [a, b, c], container: nil) == a)
        #expect(EditorRules.aboveTheLine(index: 3, siblings: [a, b, c], container: nil) == c)
        // Above the first row: the enclosing folder, or at the top level the first folder.
        #expect(EditorRules.aboveTheLine(index: 0, siblings: [a, b, c], container: container) == container)
        #expect(EditorRules.aboveTheLine(index: 0, siblings: [a, b, c], container: nil) == a)
        #expect(EditorRules.aboveTheLine(index: 0, siblings: [], container: nil) == nil)
    }

    @Test func plurals() {
        #expect(EditorRules.count(1, "connection") == "1 connection")
        #expect(EditorRules.count(0, "folder") == "0 folders")
        #expect(EditorRules.count(2, "folder") == "2 folders")
    }

    @Test func uniqueNames() {
        #expect(EditorRules.uniqueName("New Connection", taken: []) == "New Connection")
        #expect(EditorRules.uniqueName("New Connection", taken: ["New Connection"]) == "New Connection 2")
        #expect(EditorRules.uniqueName("New Connection", taken: ["New Connection", "New Connection 2"]) == "New Connection 3")
        #expect(EditorRules.uniqueName("web", taken: ["web", "web 3"]) == "web 2")
    }

    @Test func portParsing() {
        #expect(EditorRules.parsePort("", type: .ssh) == (nil, nil))
        #expect(EditorRules.parsePort(" 22 ", type: .ssh) == (nil, nil))
        #expect(EditorRules.parsePort("22", type: .vnc) == (22, nil))
        #expect(EditorRules.parsePort("5900", type: .vnc) == (nil, nil))
        #expect(EditorRules.parsePort("2222", type: .ssh) == (2222, nil))
        #expect(EditorRules.parsePort("abc", type: .ssh).problem == "The port must be a number.")
        #expect(EditorRules.parsePort("0", type: .ssh).problem == "The port must be between 1 and 65535.")
        #expect(EditorRules.parsePort("65536", type: .ssh).problem == "The port must be between 1 and 65535.")
    }

    @Test func moveTargetsExcludeOwnSubtreeAndParent() {
        let web = Connection(name: "web", host: "web")
        let inner = ConnectionFolder(name: "inner")
        let aws = ConnectionFolder(name: "aws", connections: [web], folders: [inner])
        let prod = ConnectionFolder(name: "prod", folders: [aws])
        let dev = ConnectionFolder(name: "dev")
        var library = ConnectionLibrary(folders: [prod, dev])

        #expect(library.moveTargets(for: .folder(aws.id)).map(\.name) == ["dev"])
        #expect(library.moveTargets(for: .folder(prod.id)).map(\.name) == ["dev"])
        #expect(library.moveTargets(for: .connection(web.id)).map(\.name) == ["prod", "inner", "dev"])

        // Into its own subtree: refused, nothing changes.
        let before = library
        let intoOwnSubtree = library.move(.folder(prod.id), to: inner.id)
        #expect(!intoOwnSubtree)
        #expect(library == before)

        let toDev = library.move(.folder(aws.id), to: dev.id)
        #expect(toDev)
        #expect(library.folderPath(of: inner.id).map(\.name) == ["dev", "aws", "inner"])
        let toTop = library.move(.folder(aws.id), to: nil)
        #expect(toTop)
        #expect(library.folders.map(\.name) == ["prod", "dev", "aws"])
        let alreadyTop = library.move(.folder(aws.id), to: nil)
        #expect(!alreadyTop)

        let connectionToDev = library.move(.connection(web.id), to: dev.id)
        #expect(connectionToDev)
        #expect(library.path(of: web.id).map(\.name) == ["dev"])
        let removedConnection = library.remove(.connection(web.id))
        #expect(removedConnection != nil)
        #expect(library.connection(web.id) == nil)
        let removedFolder = library.remove(.folder(inner.id))
        #expect(removedFolder != nil)
        #expect(library.folder(inner.id) == nil)
    }

    @Test func movesToAPosition() {
        let a = Connection(name: "a", host: "a"), b = Connection(name: "b", host: "b"), c = Connection(name: "c", host: "c")
        let x = ConnectionFolder(name: "x"), y = ConnectionFolder(name: "y"), z = ConnectionFolder(name: "z")
        let dev = ConnectionFolder(name: "dev", connections: [a, b, c], folders: [x, y, z])
        let prod = ConnectionFolder(name: "prod")
        var library = ConnectionLibrary(folders: [dev, prod])
        var moved = false
        func names(_ id: ConnectionFolder.ID) -> [String] { library.folder(id)!.connections.map(\.name) }

        // `at` is the index among the current siblings, as a drop between rows reports it: moving
        // `a` to before `c` (index 2) lands it after `b`.
        moved = library.move(.connection(a.id), to: dev.id, at: 2)
        #expect(moved)
        #expect(names(dev.id) == ["b", "a", "c"])
        moved = library.move(.connection(c.id), to: dev.id, at: 0)
        #expect(moved)
        #expect(names(dev.id) == ["c", "b", "a"])
        // Same place: nothing changes, and it isn't an error.
        moved = library.move(.connection(c.id), to: dev.id, at: 0)
        #expect(moved)
        #expect(names(dev.id) == ["c", "b", "a"])
        // Into another folder at a position; past the end appends.
        moved = library.move(.connection(b.id), to: prod.id, at: 0)
        #expect(moved)
        moved = library.move(.connection(a.id), to: prod.id, at: 99)
        #expect(moved)
        #expect(names(prod.id) == ["b", "a"] && names(dev.id) == ["c"])

        // Folders reorder among their siblings and at the top level the same way.
        moved = library.move(.folder(z.id), to: dev.id, at: 0)
        #expect(moved)
        #expect(library.folder(dev.id)!.folders.map(\.name) == ["z", "x", "y"])
        moved = library.move(.folder(prod.id), to: nil, at: 0)
        #expect(moved)
        #expect(library.folders.map(\.name) == ["prod", "dev"])
        moved = library.move(.folder(x.id), to: nil, at: 1)
        #expect(moved)
        #expect(library.folders.map(\.name) == ["prod", "x", "dev"])
        // Still never into its own subtree.
        moved = library.move(.folder(dev.id), to: y.id, at: 0)
        #expect(!moved)
    }

    @Test func snippetsMoveBetweenAndWithinGroups() {
        let s1 = Snippet(name: "1", keyword: ";1", text: ""), s2 = Snippet(name: "2", keyword: ";2", text: "")
        let s3 = Snippet(name: "3", keyword: ";3", text: "")
        let work = SnippetGroup(name: "work", snippets: [s1, s2, s3]), home = SnippetGroup(name: "home", snippets: [])
        var library = SnippetLibrary(groups: [work, home])
        var moved = false
        func names(_ id: SnippetGroup.ID) -> [String] { library.groups.first { $0.id == id }!.snippets.map(\.name) }

        moved = library.moveSnippet(s1.id, to: work.id, at: 3)
        #expect(moved)
        #expect(names(work.id) == ["2", "3", "1"])
        moved = library.moveSnippet(s3.id, to: home.id, at: nil)
        #expect(moved)
        moved = library.moveSnippet(s2.id, to: home.id, at: 0)
        #expect(moved)
        #expect(names(home.id) == ["2", "3"] && names(work.id) == ["1"])
        moved = library.moveSnippet(UUID(), to: home.id, at: 0)
        #expect(!moved)
        moved = library.moveSnippet(s1.id, to: UUID(), at: 0)
        #expect(!moved)

        moved = library.moveGroup(home.id, to: 0)
        #expect(moved)
        #expect(library.groups.map(\.name) == ["home", "work"])
        moved = library.moveGroup(home.id, to: 2)
        #expect(moved)
        #expect(library.groups.map(\.name) == ["work", "home"])
        moved = library.moveGroup(UUID(), to: 0)
        #expect(!moved)
    }

    @Test func sidebarItemsRoundTripAsDragText() {
        let id = UUID()
        for item in [SidebarItem.folder(id), .connection(id), .snippetGroup(id), .snippet(id)] {
            #expect(SidebarItem(dragText: item.dragText) == item)
        }
        #expect(SidebarItem(dragText: "hello") == nil)
        #expect(SidebarItem(dragText: "xpnd-sidebar:folder:not-a-uuid") == nil)
    }

    @Test func namePathsFindItemsAgain() {
        let web = Connection(name: "web", host: "web")
        let aws = ConnectionFolder(name: "aws", connections: [web])
        let library = ConnectionLibrary(folders: [ConnectionFolder(name: "prod", folders: [aws])])
        #expect(library.namePath(of: .connection(web.id)) == ["prod", "aws", "web"])
        #expect(library.namePath(of: .folder(aws.id)) == ["prod", "aws"])
        #expect(library.connection(atNamePath: ["prod", "aws", "web"])?.id == web.id)
        #expect(library.folder(atNamePath: ["prod", "aws"])?.id == aws.id)
        #expect(library.folder(atNamePath: ["aws"]) == nil)
        #expect(library.namePath(of: .folder(UUID())) == nil)
    }

    @Test func folderSudoFallbackFollowsSetting() {
        let inner = ConnectionFolder(name: "inner")
        let team = ConnectionFolder(name: "team", sudoCredential: ref("T"), folders: [ConnectionFolder(name: "sub")])
        var library = ConnectionLibrary(credential: ref("pw"), folders: [inner, team])

        #expect(library.folderSudoCredential(for: inner.id) == ResolvedCredential(ref: ref("pw"), source: .login))
        library.sudoUsesLogin = false
        #expect(library.folderSudoCredential(for: inner.id) == nil)
        #expect(library.folderSudoCredential(for: team.id) == ResolvedCredential(ref: ref("T"), source: .connection))
        #expect(library.folderSudoCredential(for: team.folders[0].id) == ResolvedCredential(ref: ref("T"), source: .folder(name: "team")))
        library.sudoCredential = ref("S")
        #expect(library.folderSudoCredential(for: inner.id) == ResolvedCredential(ref: ref("S"), source: .global))
    }

    @Test func folderCredentialsCascade() {
        let inner = ConnectionFolder(name: "inner")
        let prod = ConnectionFolder(name: "prod", credential: ref("P", .sshKey), folders: [inner])
        var library = ConnectionLibrary(credential: ref("G"), folders: [prod])

        #expect(library.folderLoginCredential(for: prod.id) == ResolvedCredential(ref: ref("P", .sshKey), source: .connection))
        #expect(library.folderLoginCredential(for: inner.id) == ResolvedCredential(ref: ref("P", .sshKey), source: .folder(name: "prod")))
        // An SSH key has no password, so sudo has nothing to fall back to.
        #expect(library.folderSudoCredential(for: inner.id) == nil)
        library.sudoCredential = ref("S")
        #expect(library.folderSudoCredential(for: inner.id) == ResolvedCredential(ref: ref("S"), source: .global))

        #expect(EditorRules.summary(library.folderLoginCredential(for: inner.id)) == "From folder prod: P (1Password)")
        #expect(EditorRules.summary(ResolvedCredential(ref: ref("G"), source: .global)) == "Global: G (1Password)")
        #expect(EditorRules.summary(ResolvedCredential(ref: ref("L"), source: .login)) == "From login credential: L (1Password)")
        #expect(EditorRules.summary(nil) == "Not set")
    }

    @Test func refreshUpdatesEveryCopy() {
        var fresh = ref("K", .sshKey)
        fresh.title = "renamed"
        fresh.username = "ubuntu"
        let web = Connection(name: "web", host: "web", credential: ref("K", .sshKey), sudoCredential: ref("other"))
        var library = ConnectionLibrary(
            credential: ref("K", .sshKey),
            folders: [ConnectionFolder(name: "prod", credential: ref("K", .sshKey), connections: [web])])
        library.refreshRefs(fresh)
        #expect(library.credential == fresh)
        #expect(library.folders[0].credential == fresh)
        #expect(library.connection(web.id)?.credential == fresh)
        #expect(library.connection(web.id)?.sudoCredential == ref("other"))
    }

    @Test func jumpHostChoices() {
        let bastion = Connection(name: "bastion", host: "b", credential: ref("K", .sshKey))
        let passwordJump = Connection(name: "pw", host: "p", credential: ref("L"))
        var web = Connection(name: "web", host: "w")
        web.credential = ref("K", .sshKey)
        var library = ConnectionLibrary(folders: [ConnectionFolder(name: "prod", connections: [bastion, passwordJump, web])])

        #expect(EditorRules.jumpHostProblem(bastion.id, for: web.id, in: library) == nil)
        #expect(EditorRules.jumpHostProblem(passwordJump.id, for: web.id, in: library) == "Jump hosts must use an SSH key")
        #expect(EditorRules.jumpHostProblem(UUID(), for: web.id, in: library) == SSHCommandError.jumpHostMissing.message)

        // bastion already jumps through web, so web → bastion would loop.
        library.editConnection(bastion.id) { $0.jumpHost = .connection(web.id) }
        #expect(EditorRules.jumpHostProblem(bastion.id, for: web.id, in: library) == SSHCommandError.jumpHostCycle.message)

        // A sixth hop is refused like a loop.
        var hops = [Connection(name: "h0", host: "h0", credential: ref("K", .sshKey))]
        for i in 1..<6 {
            hops.append(Connection(name: "h\(i)", host: "h\(i)", credential: ref("K", .sshKey), jumpHost: .connection(hops[i - 1].id)))
        }
        let chain = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: hops + [web])])
        #expect(EditorRules.jumpHostProblem(hops[4].id, for: web.id, in: chain) == nil)
        #expect(EditorRules.jumpHostProblem(hops[5].id, for: web.id, in: chain) == SSHCommandError.jumpHostChainTooLong.message)
    }
}
