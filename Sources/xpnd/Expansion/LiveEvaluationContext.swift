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

    /// A leading `~` is the home folder; relative paths are left alone and fail as not found.
    func runScript(path: String, timeoutMs: Int) async throws(ExpansionError) -> String {
        try await ScriptRunner.run(path: NSString(string: path).expandingTildeInPath, timeoutMs: timeoutMs)
    }

    func askInputs(_ labels: [String]) async -> [String: String]? { await InputForm.ask(labels) }
}
