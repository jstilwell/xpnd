import AppKit

enum LaunchError: Error, Equatable {
    case appleScriptDenied, appleScriptFailed(String), appMissing(String), failed(String), badTemplate(String)

    var message: String {
        switch self {
        case .appleScriptDenied: "xpnd isn't allowed to control the terminal. Turn it on in System Settings → Privacy & Security → Automation."
        case .appleScriptFailed(let message), .failed(let message), .badTemplate(let message): message
        case .appMissing(let name): "\(name) isn't installed."
        }
    }
}

@MainActor protocol LaunchExecuting {
    func execute(_ plan: LaunchPlan) async throws(LaunchError)
}

/// Errors never carry a script or argument: those hold the command.
@MainActor struct LiveLaunchExecutor: LaunchExecuting {
    private static let waitMs = 30_000

    func execute(_ plan: LaunchPlan) async throws(LaunchError) {
        switch plan {
        case .typeIntoFrontTerminal:
            throw .failed("xpnd couldn't type into the terminal.") // ConnectionService types these
        case .appleScript(let script):
            try await runAppleScript(script)
        case .run(LaunchPlanner.openExecutable, let arguments):
            try await runOpen(arguments)
        case .run(let executable, let arguments):
            try launchDetached(executable, arguments)
        case .builtInTab:
            throw .failed("The built-in terminal opens from the xpnd window.")
        case .openURL(let url):
            guard NSWorkspace.shared.open(url) else { throw .failed("The connection couldn't be opened.") }
        }
    }

    /// osascript, not NSAppleScript: the Automation prompt would block the main thread, and with it
    /// the event tap and all typing.
    private func runAppleScript(_ script: String) async throws(LaunchError) {
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", script], timeoutMs: Self.waitMs)
        } catch {
            throw .appleScriptFailed(error == .timedOut ? "The terminal didn't respond." : "xpnd couldn't run osascript.")
        }
        if output.status != 0 { throw Self.appleScriptError(output.stderr) }
    }

    /// Waited on, unlike other `.run` plans: open returns once the app has launched, and this is
    /// the only way to learn the app is missing. A template always runs as /bin/sh, so it never lands here.
    private func runOpen(_ arguments: [String]) async throws(LaunchError) {
        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(URL(fileURLWithPath: LaunchPlanner.openExecutable), arguments: arguments, timeoutMs: Self.waitMs)
        } catch {
            throw .failed("\(TerminalPreset.ghostty.displayName) couldn't be opened.")
        }
        if output.status != 0 { throw Self.openError(output.stderr) }
    }

    /// Never waited on: a template may block for the whole session (`alacritty -e sh -c {command}`).
    /// Process keeps itself alive and reaps the child, which outlives xpnd. /dev/null throughout,
    /// so no pipe can fill.
    private func launchDetached(_ executable: String, _ arguments: [String]) throws(LaunchError) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = Self.launchEnvironment(ProcessInfo.processInfo.environment)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw .failed("The terminal command couldn't start.") }
    }

    /// A GUI app's PATH leaves out Homebrew, so `tmux new-window {command}` would exit 127 unseen.
    nonisolated static func launchEnvironment(_ inherited: [String: String]) -> [String: String] {
        let path = inherited["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/bin:/bin:/usr/sbin:/sbin" // an empty entry would mean the working directory
        return inherited.merging(["PATH": "/opt/homebrew/bin:/usr/local/bin:" + path]) { $1 }
    }

    nonisolated static func appleScriptError(_ stderr: String) -> LaunchError {
        if stderr.contains("-1743") || stderr.lowercased().contains("not allowed") { return .appleScriptDenied }
        // A missing app fails at compile time, when the script's `tell application id` can't resolve.
        if stderr.contains("-1728"), let preset = TerminalPreset.allCases.first(where: { stderr.contains("application id \"\($0.bundleID)\"") }) {
            return .appMissing(preset.displayName)
        }
        return .appleScriptFailed("The terminal couldn't run the command.")
    }

    nonisolated static func openError(_ stderr: String) -> LaunchError {
        let name = TerminalPreset.ghostty.displayName
        return stderr.contains("Unable to find application") ? .appMissing(name) : .failed("\(name) couldn't be opened.")
    }
}
