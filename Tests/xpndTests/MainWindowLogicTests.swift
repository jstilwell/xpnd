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

    func status() async -> ProviderStatus { .notInstalled }
    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem] { [] }
    func password(for ref: CredentialRef) async throws(CredentialError) -> String { throw .locked }
    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String {
        await withCheckedContinuation { gate = $0 }
        return "ssh-ed25519 AAAA test\n"
    }
}

/// Two signed-in accounts.
private struct TwoAccountProvider: CredentialProvider {
    func status() async -> ProviderStatus {
        .ready([ProviderAccount(id: "A1", email: "a@x", url: "x"), ProviderAccount(id: "A2", email: "b@x", url: "x")])
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
        connect: { _ in })
    return (editing, directory)
}

@Suite struct MainWindowLogicTests {
    @MainActor @Test func accountPrefersTheSettingWhileListed() async throws {
        #expect(try await editing(TwoAccountProvider()).0.account() == "A1")
        #expect(try await editing(TwoAccountProvider(), account: "A2").0.account() == "A2")
        // An account 1Password no longer lists falls back to the first.
        #expect(try await editing(TwoAccountProvider(), account: "gone").0.account() == "A1")
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
