import Foundation
import Testing
@testable import xpnd

@MainActor private final class FakeSender: KeystrokeSending {
    var log: [String] = []
    var onBackspace: (() -> Void)?
    func backspace(times: Int) async {
        log.append("bs \(times)")
        onBackspace?()
    }
    func paste(_ text: String) async { log.append("paste \(text)") }
    func press(_ key: KeyName, times: Int) async { log.append("key \(key) x\(times)") }
    func press(_ combo: KeyCombo) async { log.append("combo") }
}

private struct FakeActions: ActionRunning {
    func openApp(path: String) async throws(ExpansionError) {}
    func runShortcut(name: String) async throws(ExpansionError) {}
}

/// Holds `askInputs` until the test answers.
@MainActor private final class InputGate {
    var continuation: CheckedContinuation<[String: String]?, Never>?
    func wait() async -> [String: String]? { await withCheckedContinuation { continuation = $0 } }
}

private struct FakeContext: EvaluationContext {
    let library: SnippetLibrary
    let gate: InputGate
    let now = Date()
    let locale = Locale(identifier: "en_US_POSIX")
    let timeZone = TimeZone(identifier: "UTC")!
    func clipboardText() async -> String? { nil }
    func environment(_ name: String) -> String? { nil }
    func snippet(keyword: String) -> Snippet? { library.snippet(keyword: keyword) }
    func runScript(path: String, timeoutMs: Int) async throws(ExpansionError) -> String { "" }
    func askInputs(_ labels: [String]) async -> [String: String]? { await gate.wait() }
}

private struct Activation: Equatable {
    let target: ActivationTarget
    let pid: pid_t?
}

@MainActor private final class Harness {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store: SnippetStore
    let connections: ConnectionStore
    let sender = FakeSender()
    let gate = InputGate()
    var notes: [String] = []
    /// The pid the engine sees as frontmost.
    var front: pid_t? = 100
    /// What `onActivate` received, in order.
    var activated: [Activation] = []
    /// When set, `onActivate` suspends here until the test answers.
    var activationGate: InputGate?
    private(set) var engine: ExpansionEngine!

    init(_ snippets: [Snippet], folders: [ConnectionFolder] = []) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = SnippetStore(fileURL: dir.appending(path: "snippets.yaml"))
        store.load()
        try store.update { $0.groups = [SnippetGroup(name: "G", snippets: snippets)] }
        connections = ConnectionStore(fileURL: dir.appending(path: "connections.yaml"))
        connections.load()
        try connections.update { $0.folders = folders }
        let store = store, gate = gate
        engine = ExpansionEngine(
            store: store, connections: connections, player: Player(sender: sender, actions: FakeActions()),
            makeContext: { FakeContext(library: store.library, gate: gate) },
            notify: { [unowned self] in notes.append($0) },
            frontmostPID: { [unowned self] in front },
            onActivate: { [unowned self] target, pid in
                activated.append(Activation(target: target, pid: pid))
                _ = await activationGate?.wait()
            }
        )
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func type(_ characters: String...) {
        for c in characters { engine.handle(.characters(c)) }
    }

    /// Waits for the expansion started by the last keystroke, if any.
    func settle() async { await engine.pendingExpansion?.value }

    /// Writes unparsable text over a store's file and reloads it, so its last good value stays.
    func breakFile(_ name: String) throws {
        try "groups: [".write(to: dir.appending(path: name), atomically: true, encoding: .utf8)
        store.load()
        connections.load()
    }
}

/// Polls `cond` for up to two seconds.
@MainActor private func eventually(_ cond: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return cond()
}

private func snip(_ keyword: String, _ text: String) -> Snippet {
    Snippet(name: keyword, keyword: keyword, text: text)
}

@MainActor @Suite struct ExpansionEngineTests {
    @Test func matchTriggersExpansion() async throws {
        let h = try Harness([snip(";sig", "Best")])
        h.type(";", "s", "i", "g")
        await h.settle()
        #expect(h.sender.log == ["bs 4", "paste Best"])
        #expect(h.notes.isEmpty)
    }

    @Test func failedEvaluationLeavesKeyword() async throws {
        let h = try Harness([snip(";bad", "#{combo:;zz}")])
        h.type(";", "b", "a", "d")
        await h.settle()
        #expect(h.sender.log.isEmpty)
        #expect(h.notes == [ExpansionError.missingCombo(";zz").message])
    }

    @Test func typingDuringExpansionIsIgnored() async throws {
        let h = try Harness([snip(";sig", "Hi #{input:Name}")])
        h.type(";", "s", "i", "g")
        let first = try #require(h.engine.pendingExpansion)
        #expect(await eventually { h.gate.continuation != nil })
        #expect(h.engine.isExpanding)

        h.type(";", "s", "i", "g")
        // A direct call (as from the picker) is refused too.
        await h.engine.expand(snip(";x", "X"), deletingCharacters: 0)

        h.gate.continuation?.resume(returning: ["Name": "Ann"])
        await first.value
        #expect(!h.engine.isExpanding)
        #expect(h.sender.log.filter { $0.hasPrefix("bs") } == ["bs 4"])
        #expect(h.sender.log == ["bs 4", "paste Hi Ann"])
        #expect(h.engine.buffer.text.isEmpty)
    }

    @Test func disabledOrLoadErrorDoesNothing() async throws {
        let h = try Harness([snip(";sig", "Best")])
        h.engine.isEnabled = false
        h.type(";", "s", "i", "g")
        await h.settle()
        #expect(h.sender.log.isEmpty)

        h.engine.isEnabled = true
        let url = h.dir.appending(path: "snippets.yaml")
        let good = try String(contentsOf: url, encoding: .utf8)
        try "groups: [".write(to: url, atomically: true, encoding: .utf8)
        h.store.load()
        #expect(h.store.loadError != nil)
        h.type(";", "s", "i", "g")
        await h.settle()
        #expect(h.sender.log.isEmpty)

        // A key dropped during the error starts the buffer over, so `;s` + `ig` isn't `;sig`.
        try good.write(to: url, atomically: true, encoding: .utf8)
        h.store.load()
        h.type(";", "s")
        try "groups: [".write(to: url, atomically: true, encoding: .utf8)
        h.store.load()
        h.type("x")
        try good.write(to: url, atomically: true, encoding: .utf8)
        h.store.load()
        #expect(h.store.loadError == nil)
        h.type("i", "g")
        await h.settle()
        #expect(h.sender.log.isEmpty)
    }

    @Test func keysForXpndItselfDoNotExpand() async throws {
        let h = try Harness([snip(";sig", "Best")])
        // Typed into xpnd's own Settings editor or picker search field.
        for c in [";", "s", "i", "g"] { h.engine.handle(.characters(c), targetsXpnd: true) }
        await h.settle()
        #expect(h.sender.log.isEmpty)
        #expect(h.engine.buffer.text.isEmpty)

        // Started in another app, finished in xpnd: the buffer starts over.
        h.type(";", "s", "i")
        h.engine.handle(.characters("g"), targetsXpnd: true)
        #expect(h.engine.buffer.text.isEmpty)
        h.type("g")
        await h.settle()
        #expect(h.sender.log.isEmpty)
    }

    @Test func targetAppLeavingFrontCancels() async throws {
        let h = try Harness([snip(";tix", "Hi #{input:Name}")])
        h.type(";", "t", "i", "x")
        #expect(await eventually { h.gate.continuation != nil })
        h.front = 200 // the user clicked into another app while the form was open
        h.gate.continuation?.resume(returning: ["Name": "Ann"])
        await h.settle()
        #expect(!h.sender.log.contains { $0.hasPrefix("bs") })
        #expect(h.sender.log.isEmpty)
        #expect(h.notes == [ExpansionError.targetAppChanged.message])
        #expect(!h.engine.isExpanding)

        // The picker path: captured when `expand` starts.
        h.front = 100
        let picked = Task { await h.engine.expand(snip(";p", "P #{input:X}"), deletingCharacters: 0) }
        #expect(await eventually { h.gate.continuation != nil && h.engine.isExpanding })
        h.front = 300
        h.gate.continuation?.resume(returning: ["X": "x"])
        await picked.value
        #expect(h.sender.log.isEmpty)
        #expect(h.notes.count == 2)
    }

    @Test func unchangedFrontAppStillExpands() async throws {
        let h = try Harness([snip(";tix", "Hi #{input:Name}")])
        h.type(";", "t", "i", "x")
        #expect(await eventually { h.gate.continuation != nil })
        h.gate.continuation?.resume(returning: ["Name": "Ann"])
        await h.settle()
        #expect(h.sender.log == ["bs 4", "paste Hi Ann"])
        #expect(h.notes.isEmpty)
    }

    @Test func emojiKeywordDeletesByCharacter() async throws {
        let h = try Harness([snip("👍🏽!", "ok")])
        h.type("👍🏽", "!")
        await h.settle()
        #expect(h.sender.log == ["bs 2", "paste ok"])
    }

    @Test func connectionStringActivates() async throws {
        let aws = Connection(name: "aws", host: "h", activation: ";aws")
        let h = try Harness([], folders: [ConnectionFolder(name: "f", activation: "", connections: [aws])])
        h.type(";", "a", "w", "s")
        #expect(h.engine.buffer.text.isEmpty)
        await h.settle()
        #expect(h.sender.log == ["bs 4"])
        #expect(h.activated == [Activation(target: .connection(aws.id), pid: 100)])
        #expect(h.notes.isEmpty)
        #expect(!h.engine.isExpanding)
    }

    @Test func folderStringActivates() async throws {
        let dev = ConnectionFolder(name: "dev")
        let h = try Harness([], folders: [dev])
        h.type(";", "d", "e", "v")
        await h.settle()
        #expect(h.sender.log == ["bs 4"])
        #expect(h.activated == [Activation(target: .folder(dev.id), pid: 100)])
    }

    @Test func activationNeedsTheWholeBuffer() async throws {
        let h = try Harness([], folders: [ConnectionFolder(name: "dev")])
        h.type("x", ";", "d", "e", "v")
        await h.settle()
        #expect(h.sender.log.isEmpty)
        #expect(h.activated.isEmpty)
    }

    @Test func longestWinsAcrossBoth() async throws {
        let dev = ConnectionFolder(name: "dev")
        let h = try Harness([Snippet(name: "v", keyword: "v", matching: .loose, text: "V")], folders: [dev])
        h.type(";", "d", "e", "v")
        await h.settle()
        #expect(h.sender.log == ["bs 4"])
        #expect(h.activated == [Activation(target: .folder(dev.id), pid: 100)])

        // The loose snippet still fires when no activation matches the whole buffer.
        h.type("x", "v")
        await h.settle()
        #expect(h.sender.log == ["bs 4", "bs 1", "paste V"])
        #expect(h.activated.count == 1)
    }

    @Test func perFileGating() async throws {
        let dev = ConnectionFolder(name: "dev")
        let h = try Harness([snip(";sig", "Best")], folders: [dev])

        // A broken connections file pauses activations only.
        try h.breakFile("connections.yaml")
        #expect(h.connections.loadError != nil)
        h.type(";", "d", "e", "v")
        await h.settle()
        #expect(h.sender.log.isEmpty)
        #expect(h.engine.buffer.text == ";dev")
        h.engine.resetBuffer()
        h.type(";", "s", "i", "g")
        await h.settle()
        #expect(h.sender.log == ["bs 4", "paste Best"])
        #expect(h.activated.isEmpty)

        // Both broken: dropped keys reset the buffer.
        try h.breakFile("snippets.yaml")
        h.type(";", "s")
        #expect(h.engine.buffer.text.isEmpty)

        // A broken snippets file pauses snippets only.
        try FileManager.default.removeItem(at: h.dir.appending(path: "connections.yaml"))
        h.connections.load()
        try h.connections.update { $0.folders = [dev] }
        h.sender.log = []
        h.type(";", "s", "i", "g")
        await h.settle()
        #expect(h.sender.log.isEmpty)
        #expect(h.engine.buffer.text == ";sig")
        h.engine.resetBuffer()
        h.type(";", "d", "e", "v")
        await h.settle()
        #expect(h.sender.log == ["bs 4"])
        #expect(h.activated == [Activation(target: .folder(dev.id), pid: 100)])
    }

    /// The other file's last good value still counts, so a broken file can't unmask a duplicate.
    @Test func brokenFileKeepsItsStringsInTheNamespace() async throws {
        let shared = Connection(name: "s", host: "h", activation: ";x")
        let h = try Harness([snip(";x", "X")], folders: [ConnectionFolder(name: "f", activation: "", connections: [shared])])
        try h.breakFile("connections.yaml")
        h.type(";", "x")
        await h.settle()
        #expect(h.sender.log.isEmpty)
    }

    @Test func crossFileDuplicateDoesNothing() async throws {
        let shared = Connection(name: "s", host: "h", activation: ";x")
        let folder = ConnectionFolder(name: "f", activation: "", connections: [shared])
        let h = try Harness([snip(";x", "X"), Snippet(name: "x", keyword: "x", matching: .loose, text: "lower")], folders: [folder])
        h.type(";", "x")
        await h.settle()
        // Neither owner fires, but a shorter loose snippet isn't part of the conflict.
        #expect(h.sender.log == ["bs 1", "paste lower"])
        #expect(h.activated.isEmpty)
    }

    @Test func libraryEditsReachTheMatcher() async throws {
        let h = try Harness([], folders: [ConnectionFolder(name: "dev")])
        h.type(";", "d", "e") // fills the snapshot
        let prod = ConnectionFolder(name: "prod")
        try h.connections.update { $0.folders = [prod] }
        h.engine.resetBuffer()
        h.type(";", "d", "e", "v")
        await h.settle()
        #expect(h.activated.isEmpty)

        h.engine.resetBuffer()
        h.type(";", "p", "r", "o", "d")
        await h.settle()
        #expect(h.activated == [Activation(target: .folder(prod.id), pid: 100)])

        // A new snippet takes the derived string away from the folder.
        try h.store.update { $0.groups = [SnippetGroup(name: "G", snippets: [snip(";prod", "P")])] }
        h.type(";", "p", "r", "o", "d")
        await h.settle()
        #expect(h.activated.count == 1)
        #expect(h.sender.log.last == "paste P")
    }

    @Test func activationWhileBusyIsIgnored() async throws {
        let aws = Connection(name: "aws", host: "h", activation: ";aws")
        let h = try Harness(
            [snip(";sig", "Hi #{input:Name}")],
            folders: [ConnectionFolder(name: "f", activation: "", connections: [aws])])
        h.type(";", "s", "i", "g")
        let first = try #require(h.engine.pendingExpansion)
        #expect(await eventually { h.gate.continuation != nil })

        h.type(";", "a", "w", "s")
        var ran = false
        #expect(await h.engine.exclusive { ran = true } == false)
        #expect(!ran)

        h.gate.continuation?.resume(returning: ["Name": "Ann"])
        await first.value
        #expect(h.activated.isEmpty)
        #expect(h.sender.log == ["bs 4", "paste Hi Ann"])
        #expect(h.engine.buffer.text.isEmpty)
    }

    /// Typed twice fast, or a snippet typed during a connection: the running action holds the claim.
    @Test func typingDuringActivationIsIgnored() async throws {
        let aws = Connection(name: "aws", host: "h", activation: ";aws")
        let h = try Harness([snip(";sig", "Best")], folders: [ConnectionFolder(name: "f", activation: "", connections: [aws])])
        let gate = InputGate()
        h.activationGate = gate

        // Before the settle delay ends, the claim is already held.
        h.type(";", "a", "w", "s")
        #expect(h.engine.isExpanding)
        let first = try #require(h.engine.pendingExpansion)
        h.type(";", "a", "w", "s")

        #expect(await eventually { gate.continuation != nil })
        h.type(";", "a", "w", "s")
        h.type(";", "s", "i", "g")
        await h.engine.expand(snip(";x", "X"), deletingCharacters: 0)
        #expect(await h.engine.exclusive {} == false)

        gate.continuation?.resume(returning: nil)
        await first.value
        #expect(!h.engine.isExpanding)
        #expect(h.activated.count == 1)
        #expect(h.sender.log == ["bs 4"])
    }

    @Test func frontAppChangedCancelsActivation() async throws {
        let aws = Connection(name: "aws", host: "h", activation: ";aws")
        let h = try Harness([], folders: [ConnectionFolder(name: "f", activation: "", connections: [aws])])
        h.type(";", "a", "w", "s")
        h.front = 200 // left before the settle delay ended: the typed string stays
        await h.settle()
        #expect(h.sender.log.isEmpty)
        #expect(h.activated.isEmpty)
        #expect(h.notes == [ExpansionError.targetAppChanged.message])
        #expect(!h.engine.isExpanding)
    }

    @Test func frontAppChangedDuringDeleteCancelsActivation() async throws {
        let aws = Connection(name: "aws", host: "h", activation: ";aws")
        let h = try Harness([], folders: [ConnectionFolder(name: "f", activation: "", connections: [aws])])
        h.sender.onBackspace = { [unowned h] in h.front = 200 }
        h.type(";", "a", "w", "s")
        await h.settle()
        #expect(h.sender.log == ["bs 4"])
        #expect(h.activated.isEmpty)
        #expect(h.notes == [ExpansionError.targetAppChanged.message])
        #expect(!h.engine.isExpanding)
    }

    @Test func exclusiveHoldsTheClaimWhileItsBodyRuns() async throws {
        let h = try Harness([snip(";sig", "Best")])
        var seen = false
        let ran = await h.engine.exclusive {
            seen = h.engine.isExpanding
            h.type(";", "s", "i", "g")
        }
        #expect(ran)
        #expect(seen)
        #expect(!h.engine.isExpanding)
        await h.settle()
        #expect(h.sender.log.isEmpty)
    }
}
