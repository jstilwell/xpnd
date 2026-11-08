import AppKit
import Testing
@testable import xpnd

@MainActor private final class FakeHost: TerminalHost {
    let view = NSView()
    var onExit: ((Int32?) -> Void)?
    var onDisconnect: ((String?) -> Void)?
    var onReconnecting: (() -> Void)?
    var terminated = false
    var reconnects = 0
    func terminate() { terminated = true }
    func apply(_ settings: BuiltInTerminalSettings) {}
    var onReconnect: () -> Void = {}
    func reconnect() {
        reconnects += 1
        onReconnect()
    }
    var commandUsed = 0
    func noteCommandUsed() { commandUsed += 1 }
    func exit(_ status: Int32?) { onExit?(status) }
    func disconnect(_ reason: String?) { onDisconnect?(reason) }
    /// Whether a password prompt is at the cursor.
    var atPrompt = false
    var sent: [String] = []
    func sendPassword(_ password: String) -> Bool {
        guard atPrompt else { return false }
        atPrompt = false
        sent.append(password)
        return true
    }
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

    private let connectionX = Connection(name: "x", host: "x")
    private let connectionY = Connection(name: "y", host: "y")

    private func open(_ connection: Connection) -> TerminalSession.ID {
        sessions.open(.terminal(SSHCommand(arguments: ["ssh", connection.host])), for: connection, color: nil)
    }

    @Test func aShortcutTellsTheSelectedHostFirst() {
        open("x")
        open("y")
        var seen: [Int] = []
        sessions.shortcut { seen = hosts.all.map(\.commandUsed) }
        #expect(seen == [0, 1])
    }

    @Test func aShortcutWithNoTabsStillRuns() {
        var ran = false
        sessions.shortcut { ran = true }
        #expect(ran)
    }

    @Test func anSSHTabIsEstablishedWhileItRuns() {
        let x = sessions.open(.terminal(SSHCommand(arguments: ["ssh", "x"])), for: connectionX, color: nil)
        #expect(sessions.establishedConnectionIDs == [connectionX.id])
        hosts.all[0].exit(1)
        #expect(sessions.establishedConnectionIDs.isEmpty)
        sessions.close(x)
    }

    @Test func liveConnectionIDsFollowSessions() {
        let a = open(connectionX)
        open(connectionY)
        #expect(sessions.liveConnectionIDs == [connectionX.id, connectionY.id])
        hosts.all[1].exit(1)
        #expect(sessions.liveConnectionIDs == [connectionX.id])
        sessions.close(a)
        #expect(sessions.liveConnectionIDs.isEmpty)
    }

    @Test func sessionForConnectionFindsTheLiveOne() {
        let first = open(connectionX)
        hosts.all[0].exit(1)
        let second = open(connectionX)
        #expect(sessions.session(for: connectionX.id)?.id == second)
        #expect(sessions.session(for: connectionY.id) == nil)
        sessions.close(second)
        #expect(sessions.session(for: connectionX.id)?.id == first) // an ended tab can still be shown
    }

    @Test func sessionForConnectionPrefersTheSelectedTab() {
        let first = open(connectionX)
        let second = open(connectionX)
        #expect(sessions.session(for: connectionX.id)?.id == second)
        sessions.selected = first
        #expect(sessions.session(for: connectionX.id)?.id == first)
    }

    @Test func aDesktopReconnectingByItselfShowsAsRunningAgain() {
        let id = openDesktop("win")
        hosts.all[0].disconnect("the network connection was lost")
        hosts.all[0].onReconnecting?()
        #expect(sessions.sessions.first { $0.id == id }?.state == .running)
        // So closing it now ends the session it started.
        sessions.close(id)
        #expect(hosts.all[0].terminated)
    }

    @Test func closingADisconnectedDesktopTerminatesIt() {
        let a = openDesktop("a")
        openDesktop("b")
        hosts.all[0].disconnect("the network connection was lost")
        hosts.all[1].disconnect("the network connection was lost")
        sessions.close(a) // its passwords live until terminate
        #expect(hosts.all[0].terminated)
        sessions.terminateAll()
        #expect(hosts.all[1].terminated)
    }

    @Test func anEndedTerminalIsNotTerminatedAgain() {
        let a = open("a")
        hosts.all[0].exit(1)
        sessions.close(a)
        #expect(!hosts.all[0].terminated)
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

    @Test func automaticOfferSendsOnceThePromptShows() async throws {
        open("a")
        let host = hosts.all[0]
        let offer = Task { await sessions.offer("Password", password: "pw", for: sessions.sessions[0].connectionID, automatic: true) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.sent.isEmpty)
        host.atPrompt = true
        #expect(await offer.value)
        #expect(host.sent == ["pw"])
        #expect(sessions.sessions[0].passwordOffer == nil)
    }

    @Test func clickOfferWaitsForTheClickAndCancelSendsNothing() async throws {
        open("a")
        let host = hosts.all[0]
        host.atPrompt = true
        let offer = Task { await sessions.offer("Password", password: "pw", for: sessions.sessions[0].connectionID, automatic: false) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(host.sent.isEmpty)
        sessions.sessions[0].passwordOffer?.finish(sent: false)
        #expect(await offer.value == false)
        #expect(host.sent.isEmpty)
    }

    @Test func clickSendsOnlyAtAPrompt() async throws {
        open("a")
        let host = hosts.all[0]
        let offer = Task { await sessions.offer("Password", password: "pw", for: sessions.sessions[0].connectionID, automatic: false) }
        try await Task.sleep(for: .milliseconds(50))
        let pending = try #require(sessions.sessions[0].passwordOffer)
        #expect(!pending.send(through: host))
        host.atPrompt = true
        #expect(pending.send(through: host))
        #expect(await offer.value)
        #expect(host.sent == ["pw"])
    }

    @Test func passwordPrompts() {
        for line in ["[sudo] password for jesse:", "jesse@web1's password: ", "Password:", "Enter password:"] {
            #expect(LiveTerminalHost.isPasswordPrompt(line), "\(line)")
        }
        for line in ["jesse@web1:~$ ", "Enter passphrase for key '/id':", "password", "$ cat password.txt"] {
            #expect(!LiveTerminalHost.isPasswordPrompt(line), "\(line)")
        }
    }

}
