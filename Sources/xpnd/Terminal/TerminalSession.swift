import AppKit
import Observation

/// What a tab opens: an SSH command in a terminal, or a Windows desktop. The passwords are handed to
/// the desktop's session and kept nowhere else.
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
        for session in sessions where session.needsTerminating { session.host.terminate() }
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
        sessions.remove(at: index)
        guard selected == id else { return }
        selected = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
    }
}
