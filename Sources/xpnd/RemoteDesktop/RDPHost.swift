import AppKit
import SwiftUI
import xpndRDP

/// A Windows desktop in a tab: one `XPRDPSession`, whose certificate and password questions are
/// answered with sheets on the main window, and whose dropped connections are retried here (FreeRDP's
/// Mac client has no reconnect loop). The passwords live in the session and nowhere else.
@MainActor final class RDPHost: NSObject, TerminalHost, XPRDPSessionDelegate {
    /// FreeRDP's known hosts (trusted certificates) live beside `keys/`, not in `~/.config/freerdp`.
    static var configPath: String { ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "freerdp").path }

    /// Never called: a desktop ends through `onDisconnect`.
    var onExit: ((Int32?) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var view: NSView { session.view }

    private let config: RDPSessionConfig
    private let presentIn: () -> NSWindow?
    private var session: XPRDPSession!
    /// A connect succeeded since the last user start, so a transport failure is a drop worth retrying.
    private var hadConnected = false
    private var retries = 0
    private var retry: Task<Void, Never>?
    private var sheet: NSWindow?

    init(config: RDPSessionConfig, password: String, gatewayPassword: String?, presentIn: @escaping () -> NSWindow?) {
        self.config = config
        self.presentIn = presentIn
        super.init()
        // The tab's size isn't known yet: start from the window's, and Display Control corrects it once laid out.
        let window = presentIn()
        let scale = window?.backingScaleFactor ?? 2
        let size = window?.contentLayoutRect.size ?? NSSize(width: 1000, height: 640)
        let settings = config.freerdpSettings(
            configPath: Self.configPath, viewPixelSize: (Int(size.width * scale), Int(size.height * scale)),
            gatewayUsername: config.gateway?.credential?.username)
        try? FileManager.default.createDirectory(atPath: Self.configPath, withIntermediateDirectories: true)
        session = XPRDPSession(settings: settings.map { [$0.name, $0.value] }, password: password,
                               gatewayPassword: gatewayPassword, delegate: self)
        session.commandAsWindowsKey = config.commandAsWindowsKey
        if !session.start() {
            // After `onDisconnect` is set; the same name a failed reconnect reports.
            Task { [weak self] in self?.ended("ERRCONNECT_CONNECT_FAILED") }
        }
    }

    isolated deinit {
        retry?.cancel()
        session?.stop()
    }

    func terminate() {
        retry?.cancel()
        dismissSheet()
        session.stop()
    }

    func apply(_ settings: BuiltInTerminalSettings) {}

    func reconnect() {
        retry?.cancel()
        hadConnected = false
        retries = 0
        session.reconnect()
    }

    // MARK: XPRDPSessionDelegate

    func session(_ s: XPRDPSession, decideCertificate c: XPRDPCertificate, completion: @escaping (Bool) -> Void) {
        present(RDPCertificatePrompt(certificate: c) { [weak self] trust in
            self?.dismissSheet()
            completion(trust)
        }, orElse: { completion(false) })
    }

    func session(_ s: XPRDPSession, requestPasswordForUser user: String, host: String, completion: @escaping (String?) -> Void) {
        present(RDPPasswordPrompt(user: user, host: host) { [weak self] password in
            self?.dismissSheet()
            completion(password)
        }, orElse: { completion(nil) })
    }

    func session(_ s: XPRDPSession, didDisconnectWithErrorName errorName: String?) {
        guard RDPReconnectPolicy.shouldRetry(errorName: errorName, hadConnected: hadConnected, attempt: retries, config: config) else {
            return ended(errorName)
        }
        retries += 1
        retry = Task { [weak self] in
            try? await Task.sleep(for: RDPReconnectPolicy.delay)
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
