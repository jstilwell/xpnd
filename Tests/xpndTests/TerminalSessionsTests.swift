import AppKit
import Testing
@testable import xpnd

@MainActor private final class FakeHost: TerminalHost {
    let view = NSView()
    var onExit: ((Int32?) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var terminated = false
    var reconnects = 0
    func terminate() { terminated = true }
    func apply(_ settings: BuiltInTerminalSettings) {}
    var onReconnect: () -> Void = {}
    func reconnect() {
        reconnects += 1
        onReconnect()
    }
    func exit(_ status: Int32?) { onExit?(status) }
    func disconnect(_ reason: String?) { onDisconnect?(reason) }
}

@MainActor private final class HostLog { var all: [FakeHost] = [] }

@MainActor @Suite struct TerminalSessionsTests {
    private let hosts = HostLog()
    let sessions: TerminalSessions

    init() {
        let log = hosts
        sessions = TerminalSessions { _ in
            let host = FakeHost()
            log.all.append(host)
            return host
        }
    }

    @discardableResult private func open(_ name: String) -> TerminalSession.ID {
        sessions.open(.terminal(SSHCommand(arguments: ["ssh", name])), for: Connection(name: name, host: name), color: .blue)
    }

    @discardableResult private func openDesktop(_ name: String) -> TerminalSession.ID {
        let config = RDPOptions().resolved(over: .standard, host: name, port: 3389, username: nil, domain: nil)
        return sessions.open(.remoteDesktop(config, password: "", gatewayPassword: nil),
                             for: Connection(name: name, type: .rdp, host: name), color: nil)
    }

    @Test func openSelectsAndCountsLive() {
        open("a")
        let b = open("b")
        #expect(sessions.sessions.count == 2)
        #expect(sessions.selected == b)
        #expect(sessions.liveCount == 2)
    }

    @Test func cleanExitClosesAndSelectsNeighbour() {
        let a = open("a"), b = open("b"), c = open("c")
        sessions.selected = b
        hosts.all[1].exit(0)
        #expect(sessions.sessions.map(\.id) == [a, c])
        #expect(sessions.selected == c)
    }

    @Test func removingAnUnselectedTabKeepsTheSelection() {
        open("a")
        let b = open("b"), c = open("c")
        sessions.selected = b
        hosts.all[0].exit(0)
        #expect(sessions.selected == b)
        sessions.close(c)
        #expect(sessions.sessions.map(\.id) == [b])
        #expect(sessions.selected == b)
    }

    @Test func cleanExitOfSelectedLastTabSelectsPrevious() {
        open("a")
        let b = open("b"), c = open("c")
        #expect(sessions.selected == c)
        hosts.all[2].exit(0)
        #expect(sessions.selected == b)
    }

    @Test func lastCleanExitLeavesNoSelection() {
        open("a")
        hosts.all[0].exit(0)
        #expect(sessions.sessions.isEmpty)
        #expect(sessions.selected == nil)
    }

    @Test func errorExitKeepsTheTab() {
        open("a")
        hosts.all[0].exit(255)
        #expect(sessions.sessions.first?.state == .ended(255))
        #expect(sessions.liveCount == 0)
    }

    @Test func signalExitIsEndedNil() {
        open("a")
        hosts.all[0].exit(nil)
        #expect(sessions.sessions.first?.state == .ended(nil))
    }

    @Test func closeTerminatesLiveOnly() {
        let a = open("a"), b = open("b")
        hosts.all[1].exit(1)
        sessions.close(a)
        sessions.close(b)
        #expect(hosts.all[0].terminated)
        #expect(!hosts.all[1].terminated)
        #expect(sessions.sessions.isEmpty)
    }

    @Test func exitAfterCloseIsIgnored() {
        open("a")
        let b = open("b")
        sessions.close(sessions.sessions[0].id)
        hosts.all[0].exit(0)
        #expect(sessions.sessions.map(\.id) == [b])
    }

    @Test func terminateAllClears() {
        open("a"); open("b"); open("c")
        hosts.all[2].exit(1)
        sessions.terminateAll()
        #expect(hosts.all[0].terminated && hosts.all[1].terminated)
        #expect(!hosts.all[2].terminated)
        #expect(sessions.sessions.isEmpty)
        #expect(sessions.selected == nil)
    }

    @Test func openKeepsTheKind() {
        open("a")
        openDesktop("b")
        #expect(sessions.sessions.map(\.kind) == [.terminal, .remoteDesktop])
    }

    @Test func disconnectedWithReasonKeepsTheTab() {
        open("a")
        openDesktop("b")
        hosts.all[1].disconnect("logon failed")
        #expect(sessions.sessions.count == 2)
        #expect(sessions.sessions[1].state == .disconnected("logon failed"))
        #expect(sessions.liveCount == 1)
    }

    @Test func cleanDisconnectClosesTheTab() {
        let a = open("a")
        openDesktop("b")
        hosts.all[1].disconnect(nil)
        #expect(sessions.sessions.map(\.id) == [a])
        #expect(sessions.selected == a)
    }

    @Test func reconnectAsksTheHost() {
        let b = openDesktop("b")
        hosts.all[0].disconnect("the connection timed out")
        sessions.reconnect(b)
        #expect(hosts.all[0].reconnects == 1)
        #expect(sessions.sessions[0].state == .running)
        #expect(sessions.liveCount == 1)
        // Only a disconnected tab reconnects.
        sessions.reconnect(b)
        #expect(hosts.all[0].reconnects == 1)
    }

    @Test func aReconnectThatFailsAtOnceStaysDisconnected() {
        let b = openDesktop("b")
        let host = hosts.all[0]
        host.disconnect("the connection timed out")
        host.onReconnect = { [unowned host] in host.disconnect("the connection timed out") }
        sessions.reconnect(b)
        #expect(sessions.sessions[0].state == .disconnected("the connection timed out"))
    }

    @Test func terminateQuestionPluralises() {
        #expect(TerminalSessions.terminateQuestion(count: 1) == "Terminate 1 session?")
        #expect(TerminalSessions.terminateQuestion(count: 3) == "Terminate 3 sessions?")
    }
}
