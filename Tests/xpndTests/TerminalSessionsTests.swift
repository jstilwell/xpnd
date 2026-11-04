import AppKit
import Testing
@testable import xpnd

@MainActor private final class FakeHost: TerminalHost {
    let view = NSView()
    var onExit: ((Int32?) -> Void)?
    var terminated = false
    func terminate() { terminated = true }
    func apply(_ settings: BuiltInTerminalSettings) {}
    func exit(_ status: Int32?) { onExit?(status) }
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
        sessions.open(SSHCommand(arguments: ["ssh", name]), for: Connection(name: name, host: name), color: .blue)
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

    @Test func terminateQuestionPluralises() {
        #expect(TerminalSessions.terminateQuestion(count: 1) == "Terminate 1 session?")
        #expect(TerminalSessions.terminateQuestion(count: 3) == "Terminate 3 sessions?")
    }
}
