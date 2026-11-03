import Foundation
import Testing
@testable import xpnd

@MainActor private final class FakeSender: KeystrokeSending {
    var log: [String] = []
    func backspace(times: Int) async { log.append("bs \(times)") }
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

@MainActor private final class Harness {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store: SnippetStore
    let sender = FakeSender()
    let gate = InputGate()
    var notes: [String] = []
    /// The pid the engine sees as frontmost.
    var front: pid_t? = 100
    private(set) var engine: ExpansionEngine!

    init(_ snippets: [Snippet]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = SnippetStore(fileURL: dir.appending(path: "snippets.yaml"))
        store.load()
        try store.update { $0.groups = [SnippetGroup(name: "G", snippets: snippets)] }
        let store = store, gate = gate
        engine = ExpansionEngine(
            store: store, player: Player(sender: sender, actions: FakeActions()),
            makeContext: { FakeContext(library: store.library, gate: gate) },
            notify: { [unowned self] in notes.append($0) },
            frontmostPID: { [unowned self] in front }
        )
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    func type(_ characters: String...) {
        for c in characters { engine.handle(.characters(c)) }
    }

    /// Waits for the expansion started by the last keystroke, if any.
    func settle() async { await engine.pendingExpansion?.value }
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
}
