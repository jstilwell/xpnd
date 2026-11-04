import AppKit
import SwiftTerm

/// Runs `/usr/bin/ssh` in a SwiftTerm view. Nothing the session shows or types is logged or stored.
@MainActor final class LiveTerminalHost: NSObject, TerminalHost, LocalProcessTerminalViewDelegate {
    private let terminal: LocalProcessTerminalView
    private let clipboardGuard: ClipboardReadGuard
    private var exited = false
    var onExit: ((Int32?) -> Void)?
    var view: NSView { terminal }

    init(command: SSHCommand, settings: BuiltInTerminalSettings) {
        // shortcut: scrollback applies to new sessions, upgrade if SwiftTerm exposes a setter
        terminal = LocalProcessTerminalView(
            frame: .zero, font: settings.nsFont,
            options: TerminalOptions(cursorStyle: settings.cursorStyle, scrollback: settings.scrollback))
        clipboardGuard = ClipboardReadGuard(terminal)
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

/// Sits between a `LocalProcessTerminalView` and itself as its `terminalDelegate` to deny remote clipboard
/// reads (OSC 52 and Kitty's OSC 5522): the view answers OSC 52 from the general pasteboard, which would
/// send a copied password to the remote host. Everything else goes to the view unchanged.
/// `terminalDelegate` is weak, so the host keeps this.
@MainActor final class ClipboardReadGuard: TerminalViewDelegate {
    private let view: LocalProcessTerminalView

    init(_ view: LocalProcessTerminalView) {
        self.view = view
        view.terminalDelegate = self
    }

    func clipboardRead(source: TerminalView) -> Data? { nil }

    // OSC 5522: no read capability, and the read callbacks never return nil, which means "use the pasteboard".
    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities {
        view.kittyClipboardCapabilities(source: source).subtracting([.standardRead, .primaryRead])
    }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { [] }
    func kittyClipboardRead(
        source: TerminalView, location: KittyClipboardLocation, mimeType: String
    ) -> KittyClipboardReadResult? { .denied }
    func kittyClipboardRequestPermission(
        source: TerminalView, request: KittyClipboardPermissionRequest
    ) -> KittyClipboardPermissionResult {
        request.direction == .read ? .deny : view.kittyClipboardRequestPermission(source: source, request: request)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        view.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) { view.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        view.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { view.scrolled(source: source, position: position) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        view.requestOpenLink(source: source, link: link, params: params)
    }
    func bell(source: TerminalView) { view.bell(source: source) }
    func clipboardCopy(source: TerminalView, content: Data) { view.clipboardCopy(source: source, content: content) }
    func kittyClipboardWrite(
        source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent
    ) -> KittyClipboardWriteResult {
        view.kittyClipboardWrite(source: source, location: location, content: content)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        view.iTermContent(source: source, content: content)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        view.rangeChanged(source: source, startY: startY, endY: endY)
    }
    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        view.programStatusChanged(source: source, records: records)
    }
}
