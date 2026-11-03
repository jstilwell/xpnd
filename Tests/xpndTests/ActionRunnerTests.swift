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
        await #expect(throws: ExpansionError.unknownShortcut("B")) { try await runner.runShortcut(name: "B") }
    }

    @Test func shortcutsListParses() {
        #expect(ShortcutsList.parse("A\n B \n\n") == ["A", "B"])
    }
}
