import AppKit
import Testing
@testable import xpnd
import xpndRDP

/// Records what `RDPHost` asks of its session; nothing connects.
@MainActor final class FakeSession: RDPSessionControlling {
    let view = NSView()
    var commandAsWindowsKey = true
    var calls: [String] = []
    /// Runs as each connect begins, for what must already be true by then.
    var onConnect: (() -> Void)?
    func start() -> Bool { calls.append("start"); onConnect?(); return true }
    func stop() { calls.append("stop") }
    func forgetPassword() { calls.append("forgetPassword") }
    var settingsSeen: [[[String]]] = []
    func reconnect(withSettings settings: [[String]]) { settingsSeen.append(settings); calls.append("reconnect"); onConnect?() }
    var keys: [[XPRDPKeyStep]] = []
    func sendKeySequence(_ steps: [XPRDPKeyStep]) { calls.append("keys"); keys.append(steps) }
    func sendLeftClick(atViewPoint point: NSPoint) { calls.append("click") }
    func setClipboardSyncEnabled(_ enabled: Bool) { calls.append("clipboard(\(enabled))") }
    var clipboardChannelLoaded = false
    var offerResult = true
    func offerFiles(forPaste urls: [URL]) -> Bool { calls.append("offer"); return offerResult }
    var dropHandler: (([URL], NSPoint) -> Void)?
    func requestDesktopFit() -> Bool { calls.append("fit"); return true }
    func requestDesktopWidth(_ width: Int, height: Int) -> Bool { calls.append("size \(width)x\(height)"); return true }
    var connectionInfo = XPRDPConnectionInfo()
}

@MainActor struct RDPHostTests {
    private let fake = FakeSession()

    private func host(tries: Int = 2, delay: Duration = .zero) -> (RDPHost, XPRDPSession) {
        var config = RDPOptions().resolved(over: .standard, host: "win", port: 3389, username: "me", domain: nil)
        config.reconnectTries = tries
        let fake = fake
        let host = RDPHost(config: config, password: "p", gatewayPassword: nil, presentIn: { nil }, retryDelay: delay, makeSession: { _, _, _, _, _ in fake })
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

    @Test func theNotchFollowsEveryConnectionChange() async {
        let (host, s) = host(tries: 1)
        #expect(!host.notch.isConnected)
        host.sessionDidConnect(s)
        #expect(host.notch.isConnected)
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
        #expect(!host.notch.isConnected) // retrying
        await host.retry?.value
        host.sessionDidConnect(s)
        #expect(host.notch.isConnected)
        host.reconnect()
        #expect(!host.notch.isConnected)
        host.sessionDidConnect(s)
        host.terminate()
        #expect(!host.notch.isConnected)
    }

    @Test func aReconnectTellsTheTabBeforeItCanFail() {
        let (host, _) = host()
        var calls: [String]? = nil
        host.onReconnecting = { calls = self.fake.calls }
        host.reconnect(with: { _ in })
        #expect(calls == ["start"])
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

    @Test func aSecondRejectionWithNoPromptBetweenEndsTheTab() {
        // A gateway's own stored credential refused: FreeRDP resends it without asking, so no loop.
        let (host, s) = host()
        var ended: [String?] = []
        host.onDisconnect = { ended.append($0) }
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_ACCESS_DENIED")
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_ACCESS_DENIED")
        #expect(fake.calls == ["start", "forgetPassword", "reconnect"])
        #expect(ended == ["access denied"])
        // Reconnect, clicked, asks again.
        host.reconnect()
        #expect(fake.calls.suffix(2) == ["forgetPassword", "reconnect"])
    }

    @Test func aRejectionAfterAShownPromptAsksAgainOnce() {
        let (host, s) = host()
        var ended: [String?] = []
        host.onDisconnect = { ended.append($0) }
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_LOGON_FAILURE")
        host.session(s, requestPasswordForUser: "me", domain: "", host: "win") { _, _, _ in }
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_LOGON_FAILURE")
        #expect(fake.calls == ["start", "forgetPassword", "reconnect", "forgetPassword", "reconnect"])
        #expect(ended.isEmpty)
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_LOGON_FAILURE")
        #expect(fake.calls.count == 5)
        #expect(ended == ["logon failed"])
    }

    @Test func noWindowForThePasswordSheetCancels() {
        let (host, s) = host()
        var answer: (String, String, String?)?
        host.session(s, requestPasswordForUser: "me", domain: "", host: "win") { answer = ($0, $1, $2) }
        #expect(answer?.2 == nil)
    }

    @Test func aServerSideEndAfterConnectingEndsTheTabAtOnce() {
        let (host, s) = host()
        var ended: [String?] = []
        host.onDisconnect = { ended.append($0) }
        host.sessionDidConnect(s)
        host.session(s, didDisconnectWithErrorName: "ERRINFO_IDLE_TIMEOUT")
        #expect(host.retry == nil)
        #expect(fake.calls == ["start"])
        #expect(ended == ["the server closed the session (ERRINFO_IDLE_TIMEOUT)"])
    }

    @Test func terminateCancelsAPendingRetry() async {
        let (host, s) = host(delay: .seconds(60))
        host.sessionDidConnect(s)
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
        host.terminate()
        await host.retry?.value
        #expect(fake.calls == ["start", "stop"])
    }

    @Test func reconnectWithChangesRebuildsSettingsAndKeepsThePasswordRules() {
        let (host, s) = host()
        host.reconnect(with: { $0.audio = .off })
        #expect(fake.calls == ["start", "reconnect"])
        #expect(host.config.audio == .off)
        #expect(fake.settingsSeen.last?.isEmpty == false)
        // After a rejected login the password is forgotten before the reconnect, as `reconnect()` does.
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_LOGON_FAILURE")
        host.reconnect(with: { $0.clipboard = false })
        #expect(fake.calls.suffix(2) == ["forgetPassword", "reconnect"])
        #expect(!host.config.clipboard)
    }

    @Test func sendsAndPastesOnlyWhenConnected() {
        let (host, s) = host()
        host.send(RDPKeySequence.winR)
        #expect(!host.pasteFiles([URL(fileURLWithPath: "/tmp/a")], at: .zero))
        #expect(fake.calls == ["start"])
        host.sessionDidConnect(s)
        host.send(RDPKeySequence.winR)
        #expect(host.pasteFiles([URL(fileURLWithPath: "/tmp/a")], at: .zero))
        #expect(fake.calls == ["start", "keys", "offer", "click", "keys"])
        #expect(host.requestDisplay(.fit))
        host.session(s, didDisconnectWithErrorName: "ERRINFO_IDLE_TIMEOUT")
        #expect(!host.requestDisplay(.fit))
    }

    @Test func disconnectEndsCleanlyWithoutAReconnect() {
        let (host, _) = host()
        var ended: [String?] = []
        host.onDisconnect = { ended.append($0) }
        host.disconnect()
        #expect(ended.count == 1 && ended[0] == nil)
        #expect(fake.calls == ["start", "stop"])
    }

    @Test func theDropHandlerReachesTheNotch() {
        let (host, s) = host()
        host.sessionDidConnect(s)
        fake.dropHandler?([URL(fileURLWithPath: "/tmp/a")], .zero)
        #expect(fake.calls == ["start", "offer", "click", "keys"])
        #expect(host.notch.notice == "Pasting 1 file…")
    }

    @Test func aRetryCarriesLiveDisplayAndClipboardChanges() async {
        let (host, s) = host(tries: 2)
        host.sessionDidConnect(s)
        #expect(host.requestDisplay(.fixed(width: 1920, height: 1080)))
        host.setClipboardSync(false)
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
        await host.retry?.value
        let names = Dictionary(fake.settingsSeen.last!.map { ($0[0], $0[1]) }, uniquingKeysWith: { $1 })
        #expect(names["FreeRDP_DesktopWidth"] == "1920")
        #expect(names["FreeRDP_DesktopHeight"] == "1080")
        #expect(names["FreeRDP_RedirectClipboard"] == "FALSE")
    }

    @Test func aFixedDisplayRequestGoesToTheSession() {
        let (host, s) = host()
        host.sessionDidConnect(s)
        #expect(host.requestDisplay(.fixed(width: 1280, height: 720)))
        #expect(fake.calls.last == "size 1280x720")
    }
}
