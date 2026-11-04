import AppKit
import Testing
@testable import xpnd
import xpndRDP

/// Records what `RDPHost` asks of its session; nothing connects.
@MainActor private final class FakeSession: RDPSessionControlling {
    let view = NSView()
    var commandAsWindowsKey = true
    var calls: [String] = []
    func start() -> Bool { calls.append("start"); return true }
    func stop() { calls.append("stop") }
    func reconnect() { calls.append("reconnect") }
    func forgetPassword() { calls.append("forgetPassword") }
}

@MainActor struct RDPHostTests {
    private let fake = FakeSession()

    private func host(tries: Int = 2, delay: Duration = .zero) -> (RDPHost, XPRDPSession) {
        var config = RDPOptions().resolved(over: .standard, host: "win", port: 3389, username: "me", domain: nil)
        config.reconnectTries = tries
        let fake = fake
        let host = RDPHost(config: config, password: "p", gatewayPassword: nil, presentIn: { nil }, retryDelay: delay) { _, _, _, _ in fake }
        // Only the delegate methods' first argument; never started.
        let session = XPRDPSession(settings: [], password: "", gatewayPassword: nil, delegate: host)
        return (host, session)
    }

    @Test func aTransportDropAfterConnectingIsRetriedUpToTheTriesThenEnds() async {
        let (host, s) = host(tries: 2)
        var ended: [String?] = []
        host.onDisconnect = { ended.append($0) }
        host.sessionDidConnect(s)
        for _ in 0..<2 {
            host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
            await host.retry?.value
        }
        #expect(fake.calls == ["start", "reconnect", "reconnect"])
        #expect(ended.isEmpty)
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
        #expect(fake.calls.count == 3)
        #expect(ended == ["the network connection was lost"])
    }

    @Test func aRejectedLoginForgetsThePasswordAndAsksAgainAtOnce() {
        let (host, s) = host()
        var ended: [String?] = []
        host.onDisconnect = { ended.append($0) }
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_LOGON_FAILURE")
        #expect(fake.calls == ["start", "forgetPassword", "reconnect"])
        #expect(ended.isEmpty)
        // Cancelling the sheet that reconnect brings ends the tab.
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_CANCELLED")
        #expect(ended == ["cancelled"])
    }

    @Test func noWindowForThePasswordSheetCancels() {
        let (host, s) = host()
        var answer: (String, String, String?)?
        host.session(s, requestPasswordForUser: "me", domain: "", host: "win") { answer = ($0, $1, $2) }
        #expect(answer?.2 == nil)
    }

    @Test func terminateCancelsAPendingRetry() async {
        let (host, s) = host(delay: .seconds(60))
        host.sessionDidConnect(s)
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
        host.terminate()
        await host.retry?.value
        #expect(fake.calls == ["start", "stop"])
    }
}
