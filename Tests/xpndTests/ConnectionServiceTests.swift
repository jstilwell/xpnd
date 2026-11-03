import Foundation
import Testing
@testable import xpnd

private let terminalPID: pid_t = 100
private let otherPID: pid_t = 200
private let inTerminal: (pid: pid_t, bundleID: String?) = (terminalPID, "com.apple.Terminal")
private let inSafari: (pid: pid_t, bundleID: String?) = (otherPID, "com.apple.Safari")
private let moved = ExpansionError.targetAppChanged.message

private func ref(_ item: String, _ category: CredentialCategory, username: String? = nil) -> CredentialRef {
    CredentialRef(account: "acct", vault: "vault", item: item, title: item, category: category, username: username)
}

private let key = ref("key", .sshKey)
private let login = ref("login", .login)
private let sudo = ref("sudo", .password)

/// Polls `condition` for up to two seconds.
@MainActor private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Every fake writes to one log, so tests can assert the order across them.
@MainActor private final class Log {
    var events: [String] = []
}

@MainActor private final class FakeProvider: CredentialProvider {
    let log: Log
    var passwordFailures: [String: CredentialError] = [:]
    var publicKeyFailure: CredentialError?
    var onPublicKey: () -> Void = {}
    /// Items whose password fetch waits for `release`, like an unanswered Touch ID prompt.
    var held: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]

    init(log: Log) { self.log = log }

    func status() async -> ProviderStatus { .notInstalled }
    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem] { [] }

    func password(for ref: CredentialRef) async throws(CredentialError) -> String {
        log.events.append("password \(ref.item)")
        if held.contains(ref.item) { await withCheckedContinuation { gates[ref.item] = $0 } }
        if let failure = passwordFailures[ref.item] { throw failure }
        return "secret-\(ref.item)"
    }

    func isHolding(_ item: String) -> Bool { gates[item] != nil }
    func release(_ item: String) { gates.removeValue(forKey: item)?.resume() }

    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String {
        log.events.append("publicKey \(ref.item)")
        onPublicKey()
        if let publicKeyFailure { throw publicKeyFailure }
        return "ssh-ed25519 AAAA \(ref.item)\n"
    }
}

@MainActor private final class FakeExecutor: LaunchExecuting {
    let log: Log
    var failure: LaunchError?
    private(set) var plans: [LaunchPlan] = []

    init(log: Log) { self.log = log }

    func execute(_ plan: LaunchPlan) async throws(LaunchError) {
        log.events.append("execute")
        plans.append(plan)
        if let failure { throw failure }
    }
}

@MainActor private final class FakeSender: KeystrokeSending {
    let log: Log
    var onPaste: () -> Void = {}

    init(log: Log) { self.log = log }

    func backspace(times: Int) async { log.events.append("backspace x\(times)") }
    func paste(_ text: String) async {
        onPaste()
        log.events.append("paste \(text)")
    }
    func press(_ key: KeyName, times: Int) async { log.events.append("key \(key) x\(times)") }
    func press(_ combo: KeyCombo) async { log.events.append("combo") }
}

@MainActor private final class FakePrompt: PasswordPrompting {
    let log: Log
    var answer = true
    /// Stays open until the task is cancelled, like an offer nobody has answered.
    var staysOpen = false

    init(log: Log) { self.log = log }

    func offerSudo(for name: String) async -> Bool {
        log.events.append("offerSudo \(name)")
        guard staysOpen else { return answer }
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        log.events.append("offer dismissed")
        return false
    }
}

@MainActor private final class Harness {
    let log = Log()
    let provider: FakeProvider
    let executor: FakeExecutor
    let sender: FakeSender
    let prompt: FakePrompt
    let store: ConnectionStore
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var keys: URL { directory.appending(path: "keys") }
    var front: (pid: pid_t, bundleID: String?)? = inTerminal
    var settings = TerminalSettings.standard
    /// Stands in for the wiring through `ExpansionEngine.whenIdle`.
    var onCopy: () -> Void = {}

    init(library: ConnectionLibrary) throws {
        provider = FakeProvider(log: log)
        executor = FakeExecutor(log: log)
        sender = FakeSender(log: log)
        prompt = FakePrompt(log: log)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ConnectionStore(fileURL: directory.appending(path: "connections.yaml"))
        try store.update { $0 = library }
    }

    convenience init(_ connections: Connection...) throws {
        try self.init(library: ConnectionLibrary(folders: [ConnectionFolder(name: "prod", connections: connections)]))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func service() -> ConnectionService {
        ConnectionService(
            connections: store, provider: { [provider] in provider }, executor: executor, sender: sender,
            terminal: { [unowned self] in settings },
            frontmost: { [unowned self] in front },
            notify: { [log] in log.events.append("notify \($0)") },
            copySecret: { [unowned self] secret in
                onCopy()
                log.events.append("copy \(secret)")
            },
            prompt: prompt, keysDirectory: keys)
    }

    func connect(_ connection: Connection, typedInto target: pid_t? = terminalPID) async {
        let service = service()
        await service.connect(connection.id, typedInto: target)
        await service.passwordPhase?.value
    }

    func writeKey(_ ref: CredentialRef) throws {
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try Data("ssh-ed25519 AAAA".utf8).write(to: keyFile(ref))
    }

    func keyFile(_ ref: CredentialRef) -> URL { keys.appending(path: "\(ref.item).pub") }

    func line(_ connection: Connection) throws -> String {
        try SSHCommandBuilder.build(connection.id, in: store.library, keysDirectory: keys).shellLine
    }

    func typed(_ connection: Connection) throws -> [String] {
        ["paste \(try line(connection))", "key enter x1"]
    }
}

@MainActor
struct ConnectionServiceTests {
    @Test func keyLoginTypesIntoTerminal() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key)
        let h = try Harness(aws)
        try h.writeKey(key)
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)))
    }

    @Test func passwordLoginCopiesAfterTyping() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login)
        let h = try Harness(aws)
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + ["password login", "copy secret-login", "notify Password copied for aws"])
    }

    @Test func loginThenSudo() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login, sudoCredential: sudo, autoSudo: true)
        let h = try Harness(aws)
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + [
            "password login", "copy secret-login", "notify Password copied for aws",
            "offerSudo aws", "password sudo", "copy secret-sudo", "notify Sudo password copied",
        ])
    }

    @Test func declinedSudoOfferFetchesNothing() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login, sudoCredential: sudo, autoSudo: true)
        let h = try Harness(aws)
        h.prompt.answer = false
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + [
            "password login", "copy secret-login", "notify Password copied for aws", "offerSudo aws",
        ])
    }

    @Test func sudoOnlyCopiesDirectly() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key, sudoCredential: sudo, autoSudo: true)
        let h = try Harness(aws)
        try h.writeKey(key)
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + ["password sudo", "copy secret-sudo", "notify Sudo password copied"])
    }

    @Test func noSudoPasswordMessage() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key, autoSudo: true)
        let h = try Harness(aws)
        try h.writeKey(key)
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + ["notify No sudo password set for aws"])
    }

    @Test func sudoCredentialWithoutPasswordCountsAsNone() async throws {
        let other = ref("other", .sshKey)
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key, sudoCredential: other, autoSudo: true)
        let h = try Harness(aws)
        try h.writeKey(key)
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + ["notify No sudo password set for aws"])
    }

    @Test func loginWithUnusableSudoStillSaysSo() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login, sudoCredential: key, autoSudo: true)
        let h = try Harness(aws)
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + [
            "password login", "copy secret-login", "notify Password copied for aws", "notify No sudo password set for aws",
        ])
    }

    @Test func noCredentialCopiesNothingAndSaysNothing() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3")
        let h = try Harness(aws)
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)))
    }

    @Test func noTerminalRunsPlan() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login)
        let h = try Harness(aws)
        h.front = inSafari
        await h.connect(aws, typedInto: otherPID)
        guard case .appleScript(let script) = h.executor.plans.first else {
            Issue.record("expected an AppleScript plan, got \(h.executor.plans)")
            return
        }
        #expect(script.contains("do script"))
        #expect(h.log.events == ["execute", "password login", "copy secret-login", "notify Password copied for aws"])
    }

    @Test func vncOpensURLAndCopies() async throws {
        let mac = Connection(name: "mac", type: .vnc, host: "mac.local", credential: ref("vnc", .login, username: "me"))
        let h = try Harness(mac)
        h.front = inSafari
        await h.connect(mac, typedInto: otherPID)
        #expect(h.executor.plans == [.openURL(URL(string: "vnc://me@mac.local:5900")!)])
        #expect(h.log.events == ["execute", "password vnc", "copy secret-vnc", "notify Password copied for mac"])
    }

    @Test func vncIgnoresAutoSudoAndNeedsNoKeyFile() async throws {
        let mac = Connection(name: "mac", type: .vnc, host: "mac.local", port: 5901, username: "you", autoSudo: true)
        let h = try Harness(mac)
        await h.connect(mac)
        #expect(h.executor.plans == [.openURL(URL(string: "vnc://you@mac.local:5901")!)])
        #expect(h.log.events == ["execute", "notify No password set for mac"])
    }

    /// An SSH key has no password to copy, so VNC opens and says so instead of failing in op.
    @Test func vncWithKeyCredentialSaysNoPassword() async throws {
        let mac = Connection(name: "mac", type: .vnc, host: "mac.local", credential: key)
        let h = try Harness(mac)
        await h.connect(mac)
        #expect(h.log.events == ["execute", "notify No password set for mac"])
    }

    @Test func vncFromATerminalIsNotTyped() async throws {
        let mac = Connection(name: "mac", type: .vnc, host: "mac.local", credential: login)
        let h = try Harness(mac)
        await h.connect(mac)
        #expect(h.log.events == ["execute", "password login", "copy secret-login", "notify Password copied for mac"])
    }

    @Test func badVNCHostNotifies() async throws {
        let mac = Connection(name: "mac", type: .vnc, host: "a b", credential: login)
        let h = try Harness(mac)
        await h.connect(mac)
        #expect(h.log.events == ["notify That VNC host isn't valid."])
    }

    @Test func builderErrorNotifies() async throws {
        var a = Connection(name: "a", host: "a", credential: key)
        var b = Connection(name: "b", host: "b", credential: key)
        a.jumpHost = .connection(b.id)
        b.jumpHost = .connection(a.id)
        let h = try Harness(a, b)
        await h.connect(a)
        #expect(h.log.events == ["notify \(SSHCommandError.jumpHostCycle.message)"])
    }

    @Test func badTemplateNotifies() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login)
        let h = try Harness(aws)
        h.front = inSafari
        h.settings.whenNoTerminal = .custom(template: "term \"{command}\"")
        await h.connect(aws, typedInto: otherPID)
        #expect(h.log.events == ["notify Leave {command} outside quotes: xpnd quotes it for you."])
    }

    @Test func deletedConnectionNotifies() async throws {
        let h = try Harness()
        await h.service().connect(UUID(), typedInto: terminalPID)
        #expect(h.log.events == ["notify That connection no longer exists."])
    }

    @Test func launchFailureFetchesNothing() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login, sudoCredential: sudo, autoSudo: true)
        let h = try Harness(aws)
        h.front = inSafari
        h.executor.failure = .appleScriptDenied
        await h.connect(aws, typedInto: otherPID)
        #expect(h.log.events == ["execute", "notify \(LaunchError.appleScriptDenied.message)"])
    }

    @Test func providerFailureAfterTyping() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login, sudoCredential: sudo, autoSudo: true)
        let h = try Harness(aws)
        h.provider.passwordFailures = ["login": .locked]
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + ["password login", "notify \(CredentialError.locked.message)"])
    }

    @Test func sudoProviderFailureNotifiesOnce() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key, sudoCredential: sudo, autoSudo: true)
        let h = try Harness(aws)
        try h.writeKey(key)
        h.provider.passwordFailures = ["sudo": .notFound("sudo")]
        await h.connect(aws)
        #expect(h.log.events == (try h.typed(aws)) + ["password sudo", "notify \(CredentialError.notFound("sudo").message)"])
    }

    @Test func frontAppGuard() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login)
        let h = try Harness(aws)
        await h.connect(aws, typedInto: otherPID)
        #expect(h.log.events == ["notify \(moved)"])
    }

    @Test func frontAppGuardCoversLaunchesAndNoFrontApp() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login)
        let mac = Connection(name: "mac", type: .vnc, host: "mac.local", credential: login)
        let h = try Harness(aws, mac)
        h.front = inSafari
        await h.connect(aws, typedInto: terminalPID)
        await h.connect(mac, typedInto: terminalPID)
        h.front = nil
        await h.connect(aws, typedInto: terminalPID)
        #expect(h.log.events == ["notify \(moved)", "notify \(moved)", "notify \(moved)"])
    }

    @Test func nilTargetHasNoGuard() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3")
        let h = try Harness(aws)
        h.front = inSafari
        await h.connect(aws, typedInto: nil)
        #expect(h.log.events == ["execute"])
    }

    @Test func missingPublicKeyIsFetched() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key)
        let h = try Harness(aws)
        var fileAtPaste: String?
        h.sender.onPaste = { fileAtPaste = try? String(contentsOf: h.keyFile(key), encoding: .utf8) }
        await h.connect(aws)
        #expect(h.log.events == ["publicKey key"] + (try h.typed(aws)))
        #expect(fileAtPaste == "ssh-ed25519 AAAA key\n")
        let mode = try FileManager.default.attributesOfItem(atPath: h.keyFile(key).path)[.posixPermissions] as? Int
        #expect(mode == 0o644)
    }

    @Test func focusLostDuringKeyFetchRefuses() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key)
        let h = try Harness(aws)
        h.provider.onPublicKey = { h.front = inSafari }
        await h.connect(aws)
        #expect(h.log.events == ["publicKey key", "notify \(moved)"])
    }

    @Test func publicKeyFailureStopsBeforeTyping() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key)
        let h = try Harness(aws)
        h.provider.publicKeyFailure = .locked
        await h.connect(aws)
        #expect(h.log.events == ["publicKey key", "notify \(CredentialError.locked.message)"])
        #expect(!FileManager.default.fileExists(atPath: h.keyFile(key).path))
    }

    @Test func unwritableKeysDirectoryStopsBeforeTyping() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: key)
        let h = try Harness(aws)
        try Data().write(to: h.keys) // a file where the directory should go
        await h.connect(aws)
        #expect(h.log.events == ["publicKey key", "notify xpnd couldn't save the public key for “key”."])
    }

    @Test func everyHopsKeyIsFetched() async throws {
        let (k1, k2) = (ref("k1", .sshKey), ref("k2", .sshKey))
        let outer = Connection(name: "outer", host: "outer", credential: k2)
        let shared = Connection(name: "shared", host: "shared", credential: k2, jumpHost: .connection(outer.id))
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: k1, jumpHost: .connection(shared.id))
        let h = try Harness(aws, shared, outer)
        await h.connect(aws)
        #expect(h.log.events == ["publicKey k1", "publicKey k2"] + (try h.typed(aws)))
        #expect(FileManager.default.fileExists(atPath: h.keyFile(k2).path))
    }

    @Test func focusLostBetweenPasteAndReturnStops() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login)
        let h = try Harness(aws)
        h.sender.onPaste = { h.front = inSafari }
        await h.connect(aws)
        #expect(h.log.events == ["paste \(try h.line(aws))", "notify \(moved)"])
    }

    @Test func nilTargetPressesReturnWhateverIsInFront() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3")
        let h = try Harness(aws)
        h.sender.onPaste = { h.front = inSafari }
        await h.connect(aws, typedInto: nil)
        #expect(h.log.events == (try h.typed(aws)))
    }

    @Test func unsafeKeyItemIsRefused() async throws {
        for item in ["../../x", "../x"] {
            let bad = ref(item, .sshKey)
            let aws = Connection(name: "aws", host: "54.1.2.3", credential: bad)
            let h = try Harness(aws)
            if item == "../x" { try h.writeKey(bad) } // inside the temp directory: being on disk mustn't count
            await h.connect(aws)
            #expect(h.log.events == ["notify This credential link isn't valid. Choose it again from 1Password."])
        }
    }

    @Test func unsafeJumpHostKeyItemIsRefused() async throws {
        let jump = Connection(name: "jump", host: "jump", credential: ref("../../x", .sshKey))
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login, jumpHost: .connection(jump.id))
        let h = try Harness(aws, jump)
        await h.connect(aws)
        #expect(h.log.events == ["notify This credential link isn't valid. Choose it again from 1Password."])
    }

    @Test func connectReturnsBeforePasswords() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login)
        let h = try Harness(aws)
        h.provider.held = ["login"]
        let service = h.service()
        await service.connect(aws.id, typedInto: terminalPID) // would never return if it waited for the fetch
        #expect(await eventually { h.provider.isHolding("login") })
        #expect(h.log.events == (try h.typed(aws)) + ["password login"])
        h.provider.release("login")
        await service.passwordPhase?.value
        #expect(h.log.events == (try h.typed(aws)) + ["password login", "copy secret-login", "notify Password copied for aws"])
    }

    @Test func failedLaunchStartsNoPasswordPhase() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login)
        let h = try Harness(aws)
        let service = h.service()
        await service.connect(aws.id, typedInto: otherPID)
        #expect(service.passwordPhase == nil)
    }

    @Test func newerConnectDiscardsAStaleFetch() async throws {
        let (a, b) = (ref("a", .login), ref("b", .login))
        let older = Connection(name: "older", host: "older", credential: a)
        let newer = Connection(name: "newer", host: "newer", credential: b)
        let h = try Harness(older, newer)
        h.provider.held = ["a"]
        let service = h.service()
        await service.connect(older.id, typedInto: terminalPID)
        let stale = try #require(service.passwordPhase)
        #expect(await eventually { h.provider.isHolding("a") })
        await service.connect(newer.id, typedInto: terminalPID)
        await service.passwordPhase?.value
        h.provider.release("a")
        await stale.value
        #expect(h.log.events.contains("copy secret-b"))
        #expect(!h.log.events.contains("copy secret-a"))
        #expect(!h.log.events.contains("notify Password copied for older"))
    }

    @Test func staleFailureSaysNothing() async throws {
        let older = Connection(name: "older", host: "older", credential: login)
        let newer = Connection(name: "newer", host: "newer")
        let h = try Harness(older, newer)
        h.provider.held = ["login"]
        h.provider.passwordFailures = ["login": .locked]
        let service = h.service()
        await service.connect(older.id, typedInto: terminalPID)
        let stale = try #require(service.passwordPhase)
        #expect(await eventually { h.provider.isHolding("login") })
        await service.connect(newer.id, typedInto: terminalPID)
        h.provider.release("login")
        await stale.value
        #expect(!h.log.events.contains("notify \(CredentialError.locked.message)"))
    }

    @Test func cancelledDuringCopySaysNothing() async throws {
        let older = Connection(name: "older", host: "older", credential: login, sudoCredential: sudo, autoSudo: true)
        let newer = Connection(name: "newer", host: "newer")
        let h = try Harness(older, newer)
        let service = h.service()
        h.onCopy = { service.passwordPhase?.cancel() }
        await service.connect(older.id, typedInto: terminalPID)
        await service.passwordPhase?.value
        #expect(!h.log.events.contains("notify Password copied for older"))
        #expect(!h.log.events.contains("offerSudo older"))
    }

    @Test func newerConnectDismissesAnOpenOffer() async throws {
        let older = Connection(name: "older", host: "older", credential: login, sudoCredential: sudo, autoSudo: true)
        let newer = Connection(name: "newer", host: "newer")
        let h = try Harness(older, newer)
        h.prompt.staysOpen = true
        let service = h.service()
        await service.connect(older.id, typedInto: terminalPID)
        let stale = try #require(service.passwordPhase)
        #expect(await eventually { h.log.events.contains("offerSudo older") })
        await service.connect(newer.id, typedInto: terminalPID)
        await stale.value
        #expect(h.log.events.contains("offer dismissed"))
        #expect(!h.log.events.contains("password sudo"))
    }

    @Test func noMessageContainsASecret() async throws {
        let aws = Connection(name: "aws", host: "54.1.2.3", credential: login, sudoCredential: sudo, autoSudo: true)
        let h = try Harness(aws)
        await h.connect(aws)
        #expect(!h.log.events.contains { $0.hasPrefix("notify") && $0.contains("secret-") })
    }
}
