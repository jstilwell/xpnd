import AppKit
import Observation

/// What a session runs in: its view and process. The live one wraps SwiftTerm.
@MainActor protocol TerminalHost: AnyObject {
    var view: NSView { get }
    /// Called once, on the main actor: exit status 0–255, or nil for a signal or a failed start.
    var onExit: ((Int32?) -> Void)? { get set }
    func terminate()
    func apply(_ settings: BuiltInTerminalSettings)
}

@MainActor @Observable final class TerminalSession: Identifiable {
    enum State: Equatable { case running, ended(Int32?) }

    let id = UUID()
    let connectionID: Connection.ID
    let name: String
    let color: ItemColor?
    let host: any TerminalHost
    fileprivate(set) var state = State.running

    var isLive: Bool { state == .running }

    init(connection: Connection, color: ItemColor?, host: any TerminalHost) {
        connectionID = connection.id
        name = connection.name
        self.color = color
        self.host = host
    }
}

@MainActor @Observable final class TerminalSessions {
    private let makeHost: @MainActor (SSHCommand) -> any TerminalHost
    private(set) var sessions: [TerminalSession] = []
    var selected: TerminalSession.ID?

    var liveCount: Int { sessions.filter(\.isLive).count }

    init(makeHost: @escaping @MainActor (SSHCommand) -> any TerminalHost) {
        self.makeHost = makeHost
    }

    @discardableResult
    func open(_ command: SSHCommand, for connection: Connection, color: ItemColor?) -> TerminalSession.ID {
        let session = TerminalSession(connection: connection, color: color, host: makeHost(command))
        let id = session.id
        session.host.onExit = { [weak self] status in self?.ended(id, status) }
        sessions.append(session)
        selected = id
        return id
    }

    func close(_ id: TerminalSession.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if session.isLive { session.host.terminate() }
        remove(id)
    }

    func terminateAll() {
        for session in sessions where session.isLive { session.host.terminate() }
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

    /// Removes a tab; if it was selected, the tab after it (else before it) takes over.
    private func remove(_ id: TerminalSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        guard selected == id else { return }
        selected = sessions.indices.contains(index) ? sessions[index].id : sessions.last?.id
    }
}
