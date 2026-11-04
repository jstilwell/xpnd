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
    func reconnect()
    func forgetPassword()
}

extension XPRDPSession: RDPSessionControlling {}

@MainActor final class RDPHost: NSObject, TerminalHost, XPRDPSessionDelegate {
    /// FreeRDP's known hosts (trusted certificates) live beside `keys/`, not in `~/.config/freerdp`.
    static var configPath: String { ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "freerdp").path }

    /// Never called: a desktop ends through `onDisconnect`.
    var onExit: ((Int32?) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var view: NSView { session.view }

    private let config: RDPSessionConfig
    private let presentIn: () -> NSWindow?
    private var session: (any RDPSessionControlling)!
    private let retryDelay: Duration
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

    /// `makeSession` and `retryDelay` are for tests: a fake session, and no wait between retries.
    init(config: RDPSessionConfig, password: String, gatewayPassword: String?, presentIn: @escaping () -> NSWindow?,
         retryDelay: Duration = RDPReconnectPolicy.delay,
         makeSession: @MainActor ([RDPSetting], String, String?, any XPRDPSessionDelegate) -> any RDPSessionControlling = RDPHost.makeSession) {
        self.config = config
        self.presentIn = presentIn
        self.retryDelay = retryDelay
        super.init()
        // The tab's size isn't known yet: start from the window's, and Display Control corrects it once laid out.
        let window = presentIn()
        let scale = window?.backingScaleFactor ?? 2
        let size = window?.contentLayoutRect.size ?? NSSize(width: 1000, height: 640)
        let settings = config.freerdpSettings(
            configPath: Self.configPath, viewPixelSize: (Int(size.width * scale), Int(size.height * scale)))
        session = makeSession(settings, password, gatewayPassword, self)
        session.commandAsWindowsKey = config.commandAsWindowsKey
        if !session.start() {
            Task { [weak self] in self?.onDisconnect?(RDPErrorText.startFailed) } // after `onDisconnect` is set
        }
    }

    /// The real session; FreeRDP's known-hosts directory is made first.
    static func makeSession(_ settings: [RDPSetting], password: String, gatewayPassword: String?,
                            delegate: any XPRDPSessionDelegate) -> any RDPSessionControlling {
        try? FileManager.default.createDirectory(atPath: configPath, withIntermediateDirectories: true)
        return XPRDPSession(settings: settings.map { [$0.name, $0.value] }, password: password,
                            gatewayPassword: gatewayPassword, delegate: delegate)
    }

    func terminate() {
        retry?.cancel()
        dismissSheet()
        session.stop()
    }

    func apply(_ settings: BuiltInTerminalSettings) {}

    func reconnect() {
        retry?.cancel()
        awaitingPrompt = false
        hadConnected = false
        retries = 0
        // FreeRDP asks (the password sheet) only when it has no password.
        if RDPErrorText.needsNewPassword(lastError) { session.forgetPassword() }
        session.reconnect()
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
            self?.session.reconnect() // a failure to start reports before it returns
        }
    }

    func sessionDidConnect(_ s: XPRDPSession) {
        hadConnected = true
        retries = 0
    }

    // MARK: Private

    private func ended(_ errorName: String?) {
        lastError = errorName
        onDisconnect?(RDPErrorText.isClean(errorName) ? nil : RDPErrorText.reason(forErrorName: errorName, afterConnect: hadConnected))
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
