import AppKit

protocol ActionRunning: Sendable {
    /// Throws what `openApp` or `runShortcut` would for a missing app or Shortcut, before anything is played.
    func check(_ steps: [PlayStep]) async throws(ExpansionError)
    func openApp(path: String) async throws(ExpansionError)
    func runShortcut(name: String) async throws(ExpansionError)
}

extension ActionRunning {
    func check(_ steps: [PlayStep]) async throws(ExpansionError) {}
}

struct ActionRunner: ActionRunning {
    let launch: @Sendable (URL) async throws -> Void
    /// nil when they couldn't be listed.
    let shortcutNames: @Sendable () async -> [String]?

    init(
        launch: @escaping @Sendable (URL) async throws -> Void = { url in
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        },
        shortcutNames: @escaping @Sendable () async -> [String]? = { await ShortcutsList.fetch() }
    ) {
        self.launch = launch
        self.shortcutNames = shortcutNames
    }

    func check(_ steps: [PlayStep]) async throws(ExpansionError) {
        var names: [String]?
        for step in steps {
            switch step {
            case .openApp(let path) where !Self.isApp(path): throw .appNotFound(path: path)
            case .runShortcut(let name):
                let listed = if let names { names } else { await shortcutNames() }
                guard let known = listed else { throw .shortcutsUnavailable }
                names = known
                guard known.contains(name) else { throw .unknownShortcut(name) }
            default: break
            }
        }
    }

    private static func isApp(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return path.hasSuffix(".app") && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    func openApp(path: String) async throws(ExpansionError) {
        guard Self.isApp(path) else { throw .appNotFound(path: path) }
        do { try await launch(URL(fileURLWithPath: path)) } catch { throw .appNotFound(path: path) }
    }

    /// `check` has already made sure the Shortcut exists (`Player` calls it before playing).
    func runShortcut(name: String) async throws(ExpansionError) {
        do {
            let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/shortcuts"), arguments: ["run", name], timeoutMs: 30_000)
            guard r.status == 0 else { throw ExpansionError.shortcutFailed(name: name, status: r.status) }
        } catch let e as ProcessRunError {
            throw e == .timedOut ? .shortcutTimedOut(name) : .shortcutFailed(name: name, status: -1)
        } catch let e as ExpansionError { throw e } catch { throw .shortcutFailed(name: name, status: -1) }
    }
}
