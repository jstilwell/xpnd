import AppKit

protocol ActionRunning: Sendable {
    func openApp(path: String) async throws(ExpansionError)
    func runShortcut(name: String) async throws(ExpansionError)
}

struct ActionRunner: ActionRunning {
    let launch: @Sendable (URL) async throws -> Void
    let shortcutNames: @Sendable () async -> [String]

    init(
        launch: @escaping @Sendable (URL) async throws -> Void = { url in
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        },
        shortcutNames: @escaping @Sendable () async -> [String] = { await ShortcutsList.fetch() }
    ) {
        self.launch = launch
        self.shortcutNames = shortcutNames
    }

    func openApp(path: String) async throws(ExpansionError) {
        var isDir: ObjCBool = false
        guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw .appNotFound(path: path)
        }
        do { try await launch(URL(fileURLWithPath: path)) } catch { throw .appNotFound(path: path) }
    }

    func runShortcut(name: String) async throws(ExpansionError) {
        guard await shortcutNames().contains(name) else { throw .unknownShortcut(name) }
        do {
            let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["run", name], timeoutMs: 30_000)
            guard r.status == 0 else { throw ExpansionError.shortcutFailed(name: name, status: r.status) }
        } catch let e as ProcessRunError {
            throw e == .timedOut ? .shortcutTimedOut(name) : .shortcutFailed(name: name, status: -1)
        } catch let e as ExpansionError { throw e } catch { throw .shortcutFailed(name: name, status: -1) }
    }
}
