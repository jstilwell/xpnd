import Foundation
import Testing
@testable import xpnd

private final class Launched: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    func add(_ u: URL) { lock.lock(); _urls.append(u); lock.unlock() }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
}

@Suite struct ActionRunnerTests {
    @Test func missingAppPathErrors() async {
        let launched = Launched()
        let runner = ActionRunner(launch: { launched.add($0) }, shortcutNames: { [] })
        let path = "/Applications/Nope-\(UUID()).app"
        await #expect(throws: ExpansionError.appNotFound(path: path)) { try await runner.openApp(path: path) }
        #expect(launched.urls.isEmpty)
    }

    @Test func existingAppLaunches() async throws {
        let launched = Launched()
        let runner = ActionRunner(launch: { launched.add($0) }, shortcutNames: { [] })
        try await runner.openApp(path: "/System/Applications/Calculator.app")
        #expect(launched.urls.map(\.path) == ["/System/Applications/Calculator.app"])
    }

    @Test func unknownShortcutErrors() async {
        let runner = ActionRunner(launch: { _ in }, shortcutNames: { ["A"] })
        await #expect(throws: ExpansionError.unknownShortcut("B")) { try await runner.check([.runShortcut(name: "B")]) }
    }

    @Test func unreadableShortcutsListSaysSo() async {
        let runner = ActionRunner(launch: { _ in }, shortcutNames: { nil })
        await #expect(throws: ExpansionError.shortcutsUnavailable) { try await runner.check([.runShortcut(name: "A")]) }
    }

    /// `check` already listed them before playback; running one doesn't list them again.
    @Test func runningAShortcutDoesNotListThemAgain() async {
        let calls = Launched()
        let runner = ActionRunner(launch: { _ in }, shortcutNames: { calls.add(URL(fileURLWithPath: "/")); return ["A"] })
        try? await runner.runShortcut(name: "A-\(UUID())")
        #expect(calls.urls.isEmpty)
    }

    @Test func shortcutsListParses() {
        #expect(ShortcutsList.parse("A\n B \n\n") == ["A", "B"])
    }
}
