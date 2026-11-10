import AppKit
import Observation

/// What a tab opens: an SSH command in a terminal, or a Windows desktop. The passwords are handed to
/// the desktop's session and kept nowhere else.
/// How a built-in tab gets its login and sudo passwords: the clipboard, or written straight into
/// the session at a password prompt, on a click or as soon as the prompt shows.
enum TabPasswordMode: String, CaseIterable, Sendable {
    case clipboard, sendOnClick, sendAutomatically
}

enum TabRequest: Equatable {
    case terminal(SSHCommand)
    case remoteDesktop(RDPSessionConfig, password: String, gatewayPassword: String?)

    var kind: TerminalSession.Kind {
        if case .terminal = self { .terminal } else { .remoteDesktop }
    }
}

/// What a session runs in: its view and process (or connection). The live ones wrap SwiftTerm and FreeRDP.
@MainActor protocol TerminalHost: AnyObject {
    var view: NSView { get }
    /// Called once, on the main actor: exit status 0–255, or nil for a signal or a failed start.
    var onExit: ((Int32?) -> Void)? { get set }
    /// A remote desktop's end, on the main actor: nil when clean, else the reason to show. May come
    /// again after `reconnect`.
    var onDisconnect: ((String?) -> Void)? { get set }
    /// A remote desktop is connecting again, whoever asked: the tab's Reconnect or the notch.
    var onReconnecting: (() -> Void)? { get set }
    func terminate()
    func apply(_ settings: BuiltInTerminalSettings)
    /// Connects again after a disconnect.
    func reconnect()
    /// A shortcut of xpnd's used the ⌘ held down: a remote desktop mustn't take its release as a tap.
    func noteCommandUsed()
    /// The session is up, not just trying: a terminal's shell runs at once, a desktop has to connect.
    var isEstablished: Bool { get }
    /// Writes `password` and Return into the session, only at a password prompt that hasn't had one; false otherwise.
    func sendPassword(_ password: String) -> Bool
}

extension TerminalHost {
    var onDisconnect: ((String?) -> Void)? {
        get { nil }
        set {}
    }

    var onReconnecting: (() -> Void)? {
        get { nil }
        set {}
    }

    func reconnect() {}
    func noteCommandUsed() {}
    var isEstablished: Bool { true }
    func sendPassword(_ password: String) -> Bool { false }
}

/// A password waiting to go into a tab. Ends once: sent, cancelled, superseded, or after `lifetime`.
@MainActor @Observable final class PasswordOffer {
    static let lifetime: Duration = .seconds(60)
    let label: String
    let automatic: Bool
    let until = Date.now + TimeInterval(lifetime.components.seconds)
    /// Why the last click didn't send.
    var problem: String?
    private(set) var outcome: Bool?
    @ObservationIgnored private var password: String?
    @ObservationIgnored private var waiter: CheckedContinuation<Bool, Never>?

    init(label: String, password: String, automatic: Bool) {
        self.label = label
        self.password = password
        self.automatic = automatic
    }

    var isFinished: Bool { outcome != nil }

    /// True if the host took it.
    @discardableResult
    func send(through host: any TerminalHost) -> Bool {
        guard let password, host.sendPassword(password) else { return false }
        finish(sent: true)
        return true
    }

    /// Drops the password and wakes `result()`.
    func finish(sent: Bool) {
        guard outcome == nil else { return }
        outcome = sent
        password = nil
        waiter?.resume(returning: sent)
        waiter = nil
    }

    func result() async -> Bool {
        if let outcome { return outcome }
        return await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor @Observable final class TerminalSession: Identifiable {
    enum Kind: Equatable { case terminal, remoteDesktop }
    enum State: Equatable { case running, ended(Int32?), disconnected(String) }

    let id = UUID()
    let kind: Kind
    let connectionID: Connection.ID
    let name: String
    let color: ItemColor?
    let host: any TerminalHost
    fileprivate(set) var state = State.running
    /// "Sudo password copied", shown over the terminal until `until` or until the clipboard no longer holds it.
    var copiedNotice: (text: String, until: Date)?
    /// A password to send into this tab, shown over the terminal.
    var passwordOffer: PasswordOffer?

    var isLive: Bool { state == .running }
    /// A disconnected desktop is over but still holds its session and passwords until it's terminated.
    var needsTerminating: Bool {
        if case .ended = state { false } else { true }
    }

    init(connection: Connection, kind: Kind, color: ItemColor?, host: any TerminalHost) {
        self.kind = kind
        connectionID = connection.id
        name = connection.name
        self.color = color
        self.host = host
    }
}

@MainActor @Observable final class TerminalSessions {
    private let makeHost: @MainActor (TabRequest) -> any TerminalHost
    private(set) var sessions: [TerminalSession] = []
    var selected: TerminalSession.ID?

    var liveCount: Int { sessions.filter(\.isLive).count }
    /// Connections with a running session; one read per list lets SwiftUI track every session's state.
    var liveConnectionIDs: Set<Connection.ID> { Set(sessions.filter(\.isLive).map(\.connectionID)) }
    /// The ones actually connected, for the sidebar's dot; a connecting tab is only live, so it can be cancelled.
    var establishedConnectionIDs: Set<Connection.ID> {
        Set(sessions.filter { $0.isLive && $0.host.isEstablished }.map(\.connectionID))
    }

    /// The connection's running session (the selected tab if it qualifies), else any tab it still has.
    func session(for connectionID: Connection.ID) -> TerminalSession? {
        let mine = sessions.filter { $0.connectionID == connectionID }
        return mine.first { $0.isLive && $0.id == selected } ?? mine.first(where: \.isLive) ?? mine.first
    }

    init(makeHost: @escaping @MainActor (TabRequest) -> any TerminalHost) {
        self.makeHost = makeHost
    }

    @discardableResult
    func open(_ request: TabRequest, for connection: Connection, color: ItemColor?) -> TerminalSession.ID {
        let session = TerminalSession(connection: connection, kind: request.kind, color: color, host: makeHost(request))
        let id = session.id
        session.host.onExit = { [weak self] status in self?.ended(id, status) }
        session.host.onDisconnect = { [weak self] reason in self?.disconnected(id, reason) }
        session.host.onReconnecting = { [weak self] in self?.reconnecting(id) }
        sessions.append(session)
        selected = id
        return id
    }

    /// Over the connection's running tab, for as long as the clipboard keeps the password.
    func showCopied(_ text: String, for connectionID: Connection.ID) {
        guard let session = session(for: connectionID), session.isLive else { return }
        session.copiedNotice = (text, .now + TimeInterval(SecretClipboard.clearAfter.components.seconds))
    }

    /// Offers `password` over the tab `id` and returns whether it went in: the tab the connect opened, since a
    /// connection can have several. Automatic offers send as soon as a password prompt shows; either kind ends
    /// after `PasswordOffer.lifetime`, or with its tab.
    func offer(_ label: String, password: String, in id: TerminalSession.ID, automatic: Bool) async -> Bool {
        guard let session = sessions.first(where: { $0.id == id }), session.isLive else { return false }
        session.passwordOffer?.finish(sent: false)
        let offer = PasswordOffer(label: label, password: password, automatic: automatic)
        session.passwordOffer = offer
        // shortcut: polls the screen 4×/s while an offer is open; upgrade to SwiftTerm's output handler if it shows in profiles
        let watch = Task { @MainActor [weak session] in
            let deadline = ContinuousClock.now + PasswordOffer.lifetime
            while ContinuousClock.now < deadline, !offer.isFinished, let session, session.isLive {
                if automatic { offer.send(through: session.host) }
                try? await Task.sleep(for: .milliseconds(250))
            }
            offer.finish(sent: false)
        }
        let sent = await withTaskCancellationHandler {
            await offer.result()
        } onCancel: {
            Task { @MainActor in offer.finish(sent: false) }
        }
        watch.cancel()
        if session.passwordOffer === offer { session.passwordOffer = nil }
        return sent
    }

    func close(_ id: TerminalSession.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if session.needsTerminating { session.host.terminate() }
        remove(id)
    }

    /// A disconnected tab only; it shows as running until the host reports again.
    func reconnect(_ id: TerminalSession.ID) {
        guard let session = sessions.first(where: { $0.id == id }), case .disconnected = session.state else { return }
        session.state = .running
        session.host.reconnect() // may report a failure before it returns
    }

    func terminateAll() {
        for session in sessions {
            session.passwordOffer?.finish(sent: false)
            if session.needsTerminating { session.host.terminate() }
        }
        sessions = []
        selected = nil
    }

    static func terminateQuestion(count: Int) -> String {
        "Terminate \(EditorRules.count(count, "session"))?"
    }

    private func ended(_ id: TerminalSession.ID, _ status: Int32?) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if status == 0 { remove(id) } else { session.state = .ended(status) }
    }

    private func disconnected(_ id: TerminalSession.ID, _ reason: String?) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if let reason { session.state = .disconnected(reason) } else { remove(id) }
    }

    private func reconnecting(_ id: TerminalSession.ID) {
        guard let session = sessions.first(where: { $0.id == id }), case .disconnected = session.state else { return }
        session.state = .running
    }

    /// Removes a tab; if it was selected, the tab after it (else before it) takes over.
    private func remove(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        // A tab that is gone takes no password: the offer would keep it, and keep trying, for a minute.
        sessions[index].passwordOffer?.finish(sent: false)
        sessions.remove(at: index)
        guard selected == id else { return }
        selected = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
    }
}
