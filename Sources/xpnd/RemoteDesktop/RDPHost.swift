import AppKit
import SwiftUI
import xpndRDP

/// A Windows desktop in a tab: one `XPRDPSession`, whose certificate and password questions are
/// answered with sheets on the main window, and whose dropped connections are retried here (FreeRDP's
/// Mac client has no reconnect loop). The passwords live in the session and nowhere else.
@MainActor protocol RDPSessionControlling: AnyObject {
    var view: NSView { get }
    var commandAsWindowsKey: Bool { get set }
    func start() -> Bool
    func stop()
    func forgetPassword()
    func reconnect(withSettings settings: [[String]])
    func sendKeySequence(_ steps: [XPRDPKeyStep])
    func sendLeftClick(atViewPoint point: NSPoint)
    func setClipboardSyncEnabled(_ enabled: Bool)
    var clipboardChannelLoaded: Bool { get }
    func offerFiles(forPaste urls: [URL], completion: @escaping (Bool) -> Void)
    var dropHandler: (([URL], NSPoint) -> Void)? { get set }
    func requestDesktopFit() -> Bool
    func requestDesktopWidth(_ width: Int, height: Int) -> Bool
    var connectionInfo: XPRDPConnectionInfo { get }
    func noteCommandUsed()
}

extension XPRDPSession: RDPSessionControlling {}

@MainActor final class RDPHost: NSObject, TerminalHost, XPRDPSessionDelegate {
    /// FreeRDP's known hosts (trusted certificates) live beside `keys/`, not in `~/.config/freerdp`.
    static var configPath: String { ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "freerdp").path }

    /// Never called: a desktop ends through `onDisconnect`.
    var onExit: ((Int32?) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var onReconnecting: (() -> Void)?
    var view: NSView { session.view }

    /// This session's config: the notch's reconnects change it, never the connection or Settings.
    private(set) var config: RDPSessionConfig
    /// Set by the workspace: writes a display choice to the connection (the notch's "Set as default").
    private(set) var onSaveDisplayDefault: ((RDPOptions.Display) -> Bool)?
    /// A connect succeeded and the session has not ended since.
    private(set) var isConnected = false {
        didSet { notch?.isConnected = isConnected }
    }
    private(set) var notch: RDPNotchModel!
    private let presentIn: () -> NSWindow?
    private var session: (any RDPSessionControlling)!
    private let retryDelay: Duration
    private let cleanup: @MainActor () -> DropFolderCleanup
    /// A connect succeeded since the last user start, so a transport failure is a drop worth retrying.
    private var hadConnected = false
    private var retries = 0
    /// The name the last `onDisconnect` came from.
    private var lastError: String?
    /// A rejected login reconnected to ask, and no sheet has been asked for since. Another rejection then
    /// means FreeRDP sent stored credentials without asking, so the tab ends instead of looping.
    private var awaitingPrompt = false
    /// Internal for tests, which await it.
    private(set) var retry: Task<Void, Never>?
    private var sheet: NSWindow?

    /// `makeSession`, `retryDelay` and `cleanup` are for tests: a fake session, no wait between retries, a fixed policy.
    init(config: RDPSessionConfig, password: String, gatewayPassword: String?, presentIn: @escaping () -> NSWindow?,
         retryDelay: Duration = RDPReconnectPolicy.delay,
         cleanup: @escaping @MainActor () -> DropFolderCleanup = { AppSettings.shared.remoteDesktop.dropFolderCleanup },
         makeSession: @MainActor ([RDPSetting], String, String?, (name: String, path: String)?, any XPRDPSessionDelegate) -> any RDPSessionControlling = RDPHost.makeSession) {
        self.config = config
        self.presentIn = presentIn
        self.retryDelay = retryDelay
        self.cleanup = cleanup
        super.init()
        session = makeSession(freerdpSettings(), password, gatewayPassword, config.driveDevice(), self)
        session.commandAsWindowsKey = config.commandAsWindowsKey
        notch = RDPNotchModel(actions: self)
        session.dropHandler = { [weak self] urls, point in self?.notch.dropOnDesktop(urls, at: point) }
        ensureDropFolder()
        if !session.start() {
            Task { [weak self] in self?.onDisconnect?(RDPErrorText.startFailed) } // after `onDisconnect` is set
        }
    }

    /// The real session; FreeRDP's known-hosts directory is made first.
    static func makeSession(_ settings: [RDPSetting], password: String, gatewayPassword: String?,
                            drive: (name: String, path: String)?, delegate: any XPRDPSessionDelegate) -> any RDPSessionControlling {
        try? FileManager.default.createDirectory(atPath: configPath, withIntermediateDirectories: true)
        return XPRDPSession(settings: settings.map { [$0.name, $0.value] }, password: password,
                            gatewayPassword: gatewayPassword, driveName: drive?.name, drivePath: drive?.path, delegate: delegate)
    }

    /// Takes the id, not the tab's session: that owns this host, and a cycle would keep the passwords alive.
    func saveDisplay(to id: Connection.ID, with save: @escaping (Connection.ID, RDPOptions.Display) -> Bool) {
        onSaveDisplayDefault = { save(id, $0) }
    }

    func terminate() {
        isConnected = false
        retry?.cancel()
        dismissSheet()
        session.stop()
        clearDropFolderPerPolicy()
    }

    func apply(_ settings: BuiltInTerminalSettings) {}

    func noteCommandUsed() { session.noteCommandUsed() }

    func reconnect() { reconnect(with: { _ in }) }

    private func prepareReconnect() {
        isConnected = false
        retry?.cancel()
        awaitingPrompt = false
        hadConnected = false
        retries = 0
        // FreeRDP asks (the password sheet) only when it has no password.
        if RDPErrorText.needsNewPassword(lastError) { session.forgetPassword() }
        ensureDropFolder()
    }

    /// Every connect after the first uses settings rebuilt from `config`, so live changes survive a retry. The
    /// clipboard's switch outlives a connection, so it's set to agree as well.
    private func reconnectSession() {
        session.setClipboardSyncEnabled(config.clipboard)
        session.reconnect(withSettings: freerdpSettings().map { [$0.name, $0.value] })
    }

    /// The settings for `config`. The tab's size isn't known yet at first: start from the window's, and
    /// Display Control corrects it once laid out.
    private func freerdpSettings() -> [RDPSetting] {
        let window = presentIn()
        let scale = window?.backingScaleFactor ?? 2
        let size = window?.contentLayoutRect.size ?? NSSize(width: 1000, height: 640)
        return config.freerdpSettings(
            configPath: Self.configPath, viewPixelSize: (Int(size.width * scale), Int(size.height * scale)))
    }

    // MARK: XPRDPSessionDelegate

    func session(_ s: XPRDPSession, decideCertificate c: XPRDPCertificate, completion: @escaping (Bool) -> Void) {
        present(RDPCertificatePrompt(certificate: c) { [weak self] trust in
            self?.dismissSheet()
            completion(trust)
        }, orElse: { completion(false) })
    }

    func session(_ s: XPRDPSession, requestPasswordForUser user: String, domain: String, host: String,
                 completion: @escaping (String, String, String?) -> Void) {
        awaitingPrompt = false
        present(RDPPasswordPrompt(user: user, domain: domain, host: host) { [weak self] typed in
            self?.dismissSheet()
            guard let typed else { return completion("", "", nil) }
            let login = RDPLogin.split(username: typed.username, domain: typed.domain)
            completion(login.username, login.domain ?? "", typed.password)
        }, orElse: { completion("", "", nil) })
    }

    func session(_ s: XPRDPSession, didDisconnectWithErrorName errorName: String?) {
        isConnected = false
        // A rejected login asks again at once (the sheet); the password that failed is never resent.
        if RDPErrorText.needsNewPassword(errorName), !awaitingPrompt {
            lastError = errorName
            reconnect()
            awaitingPrompt = true
            return
        }
        guard RDPReconnectPolicy.shouldRetry(errorName: errorName, hadConnected: hadConnected, attempt: retries, config: config) else {
            return ended(errorName)
        }
        retries += 1
        retry = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled else { return }
            self?.ensureDropFolder()
            self?.reconnectSession() // a failure to start reports before it returns
        }
    }

    func sessionDidConnect(_ s: XPRDPSession) {
        isConnected = true
        lastError = nil // the password worked, so a later reconnect keeps it
        hadConnected = true
        retries = 0
    }

    // MARK: Private

    private func ended(_ errorName: String?) {
        lastError = errorName
        clearDropFolderPerPolicy()
        onDisconnect?(RDPErrorText.isClean(errorName) ? nil : RDPErrorText.reason(forErrorName: errorName, afterConnect: hadConnected))
    }

    private func ensureDropFolder() {
        guard let drive = config.driveDevice() else { return }
        RDPDropFolder.ensureExists(folder: URL(fileURLWithPath: drive.path))
    }

    /// Only a final end calls this, never a reconnect retry: the session that comes back still needs its files.
    private func clearDropFolderPerPolicy() {
        guard let folder = config.dropFolder,
              RDPDropFolder.shouldClear(policy: cleanup(), lastUse: nil, now: Date(), disconnecting: true) else { return }
        // shortcut: duplicate tabs of a connection share one folder, so one ending clears it for the other; track open tabs per connection to fix.
        try? RDPDropFolder.clear(folder: URL(fileURLWithPath: folder))
    }

    private func present(_ prompt: some View, orElse refuse: () -> Void) {
        guard let window = presentIn() else { return refuse() }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: prompt))
        self.sheet = sheet
        window.beginSheet(sheet)
    }

    private func dismissSheet() {
        guard let sheet else { return }
        self.sheet = nil
        sheet.sheetParent?.endSheet(sheet)
    }
}

extension RDPHost: RDPNotchActions {
    var clipboardChannelLoaded: Bool { session.clipboardChannelLoaded }
    var info: RDPConnectionInfo { RDPConnectionInfo(session.connectionInfo) }

    func send(_ steps: [RDPKeyStep]) {
        guard isConnected else { return }
        session.sendKeySequence(steps.map(\.objc))
    }

    /// The offer only queues on the channel while input goes straight out, so nothing is clicked or typed
    /// until the server has it: a Ctrl+V ahead of it would paste whatever Windows already held.
    func pasteFiles(_ urls: [URL], at point: CGPoint, done: @escaping (Bool) -> Void) {
        guard isConnected else { return done(false) }
        session.offerFiles(forPaste: urls) { [weak self] accepted in
            guard let self, accepted, isConnected else { return done(false) }
            session.sendLeftClick(atViewPoint: point)
            session.sendKeySequence(([.pause(ms: 100)] + RDPKeySequence.ctrlV).map(\.objc))
            done(true)
        }
    }

    func setClipboardSync(_ on: Bool) {
        config.clipboard = on
        session.setClipboardSyncEnabled(on)
    }

    /// Applies `changes` to this session's config, then reconnects with the settings rebuilt from it. The
    /// password handling is `reconnect()`'s.
    func reconnect(with changes: (inout RDPSessionConfig) -> Void) {
        changes(&config)
        prepareReconnect()
        onReconnecting?() // first: a failure to start reports before `reconnectSession` returns
        reconnectSession()
    }

    func requestDisplay(_ display: RDPOptions.Display) -> Bool {
        guard isConnected else { return false }
        let accepted = switch display {
        case .fit: session.requestDesktopFit()
        case let .fixed(width, height): session.requestDesktopWidth(width, height: height)
        }
        if accepted { config.display = display }
        return accepted
    }

    /// The user ends the session as closing the tab does; `stop` reports nothing, so there is no retry.
    func disconnect() {
        terminate()
        onDisconnect?(nil)
    }

    func toggleFullScreen() { view.window?.toggleFullScreen(nil) }

    /// Every notch action ends here, so a ⌘-click on a button doesn't count as tapping ⌘.
    func restoreFocus() {
        noteCommandUsed()
        _ = view.window?.makeFirstResponder(view)
    }

    func dropFolderCount() -> Int {
        config.dropFolder.map { RDPDropFolder.count(folder: URL(fileURLWithPath: $0)) } ?? 0
    }

    func copyIntoDropFolder(_ urls: [URL]) throws -> (names: [String], failures: [URL]) {
        guard let folder = config.dropFolder else { throw CocoaError(.fileNoSuchFile) }
        return try RDPDropFolder.copyIn(urls, folder: URL(fileURLWithPath: folder))
    }

    /// The user's Clear, whatever the cleanup policy; the folder is made again while the drive is redirected.
    func clearDropFolder() throws {
        guard let folder = config.dropFolder else { return }
        try RDPDropFolder.clear(folder: URL(fileURLWithPath: folder))
        ensureDropFolder()
    }

    func revealDropFolder() {
        guard let folder = config.dropFolder else { return }
        ensureDropFolder()
        NSWorkspace.shared.open(URL(fileURLWithPath: folder))
    }

    func saveDisplayAsDefault(_ display: RDPOptions.Display) -> Bool { onSaveDisplayDefault?(display) ?? false }
}
