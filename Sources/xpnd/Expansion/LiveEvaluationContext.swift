import AppKit

/// The real values an expansion reads. The library is a snapshot taken when the expansion starts,
/// so `#{combo:}` sees one consistent library even if the file reloads meanwhile.
struct LiveEvaluationContext: EvaluationContext {
    let library: SnippetLibrary
    let now = Date()
    let locale = Locale.current
    let timeZone = TimeZone.current

    func clipboardText() async -> String? {
        await MainActor.run { NSPasteboard.general.string(forType: .string) }
    }

    func environment(_ name: String) -> String? { ProcessInfo.processInfo.environment[name] }

    func snippet(keyword: String) -> Snippet? { library.snippet(keyword: keyword) }

    /// A leading `~` is the home folder. Relative paths are refused as not found: they would resolve
    /// against the app's working directory (`/`), not anything the user chose.
    func runScript(path: String, timeoutMs: Int) async throws(ExpansionError) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw .scriptNotFound(path: path) }
        return try await ScriptRunner.run(path: expanded, timeoutMs: timeoutMs)
    }

    func askInputs(_ labels: [String]) async -> [String: String]? { await InputForm.ask(labels) }
}
