import AppKit
import SwiftTerm

/// Runs `/usr/bin/ssh` in a SwiftTerm view. Nothing the session shows or types is logged or stored.
@MainActor final class LiveTerminalHost: NSObject, TerminalHost, LocalProcessTerminalViewDelegate {
    private let terminal: LocalProcessTerminalView
    private var exited = false
    var onExit: ((Int32?) -> Void)?
    var view: NSView { terminal }

    init(command: SSHCommand, settings: BuiltInTerminalSettings) {
        // shortcut: scrollback applies to new sessions, upgrade if SwiftTerm exposes a setter
        terminal = LocalProcessTerminalView(
            frame: .zero, font: settings.nsFont,
            options: TerminalOptions(cursorStyle: settings.cursorStyle, scrollback: settings.scrollback))
        super.init()
        terminal.processDelegate = self
        apply(settings)
        terminal.startProcess(
            executable: "/usr/bin/ssh", args: Array(command.arguments.dropFirst()),
            environment: Self.environment(from: ProcessInfo.processInfo.environment, locale: Locale.current.identifier),
            execName: "ssh")
    }

    static func environment(from parent: [String: String], locale: String) -> [String] {
        var env = parent
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil {
            env["LANG"] = "\(locale.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]).UTF-8"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    func terminate() { terminal.terminate() }

    func apply(_ settings: BuiltInTerminalSettings) {
        terminal.font = settings.nsFont
        let colors = settings.colors
        terminal.nativeForegroundColor = colors.foreground
        terminal.nativeBackgroundColor = colors.background
        terminal.setCursorStyle(settings.cursorStyle)
    }

    private func finish(_ status: Int32?) {
        guard !exited else { return }
        exited = true
        onExit?(status)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated { finish(exitCode) }
    }
    nonisolated func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        MainActor.assumeIsolated { finish(nil) }
    }
}
