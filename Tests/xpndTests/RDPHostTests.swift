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
    /// As the real clipboard: on until told otherwise, and a reconnect leaves it as it was.
    var clipboardEnabled = true
    func setClipboardSyncEnabled(_ enabled: Bool) { clipboardEnabled = enabled }
    var clipboardChannelLoaded = false
    /// The pending offer's answer; a test calls it as the server's response would.
    var offerDone: ((Bool) -> Void)?
    func offerFiles(forPaste urls: [URL], completion: @escaping (Bool) -> Void) { calls.append("offer"); offerDone = completion }
    var dropHandler: (([URL], NSPoint) -> Void)?
    func requestDesktopFit() -> Bool { calls.append("fit"); return true }
    func requestDesktopWidth(_ width: Int, height: Int) -> Bool { calls.append("size \(width)x\(height)"); return true }
    var connectionInfo = XPRDPConnectionInfo()
    var commandUsed = 0
    func noteCommandUsed() { commandUsed += 1 }
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

    @Test func aClosedDesktopGoesAway() {
        let fake = fake
        let sessions = TerminalSessions { request in
            guard case .remoteDesktop(let config, let password, let gateway) = request else { fatalError("a desktop only") }
            return RDPHost(config: config, password: password, gatewayPassword: gateway, presentIn: { nil }, makeSession: { _, _, _, _, _ in fake })
        }
        let config = RDPOptions().resolved(over: .standard, host: "win", port: 3389, username: "me", domain: nil)
        let id = sessions.open(.remoteDesktop(config, password: "p", gatewayPassword: nil),
                               for: Connection(name: "win", type: .rdp, host: "win"), color: nil)
        weak var host = sessions.selectedSession?.host as? RDPHost
        // As the workspace does.
        host?.saveDisplay(to: sessions.selectedSession!.connectionID) { _, _ in true }
        #expect(host != nil)
        sessions.close(id)
        #expect(host == nil)
    }

    @Test func aTabClosedDuringACopyGoesAwayWhenTheCopyEnds() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xpnd-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "a.txt")
        try Data("x".utf8).write(to: source)
        let config = RDPOptions().resolved(over: .standard, host: "win", port: 3389, username: "me", domain: nil,
                                           dropFolder: dir.appending(path: "drop").path)
        let fake = fake
        var host: RDPHost? = RDPHost(config: config, password: "p", gatewayPassword: nil, presentIn: { nil }, cleanup: { .never },
                                     makeSession: { _, _, _, _, _ in fake })
        weak let closed = host
        #expect(host?.notch.dropOnNotch([source]) == true)
        let copying = host?.notch.copying
        await Task.yield() // the copy is on its way
        host?.terminate()
        host = nil
        await copying?.value
        #expect(closed == nil)
    }

    @Test func aGoodPasswordIsKeptByALaterReconnect() {
        let (host, s) = host()
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_LOGON_FAILURE") // retyped on the sheet
        host.sessionDidConnect(s)
        fake.calls = []
        host.reconnect(with: { _ in })
        #expect(fake.calls == ["reconnect"])
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
        var pasted: [Bool] = []
        host.send(RDPKeySequence.winR)
        host.pasteFiles([URL(fileURLWithPath: "/tmp/a")], at: .zero) { pasted.append($0) }
        #expect(pasted == [false])
        #expect(fake.calls == ["start"])
        host.sessionDidConnect(s)
        host.send(RDPKeySequence.winR)
        host.pasteFiles([URL(fileURLWithPath: "/tmp/a")], at: .zero) { pasted.append($0) }
        fake.offerDone?(true)
        #expect(pasted == [false, true])
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
        #expect(fake.calls == ["start", "offer"])
        fake.offerDone?(true)
        #expect(fake.calls == ["start", "offer", "click", "keys"])
        #expect(host.notch.notice == "Pasting 1 file…")
    }

    @Test func nothingIsClickedOrTypedUntilWindowsHasTheOffer() {
        let (host, s) = host()
        host.sessionDidConnect(s)
        var pasted: [Bool] = []
        host.pasteFiles([URL(fileURLWithPath: "/tmp/a")], at: .zero) { pasted.append($0) }
        #expect(fake.calls == ["start", "offer"])
        #expect(pasted.isEmpty)
    }

    @Test func aPasteClicksThenPausesThenSendsCtrlV() throws {
        let (host, s) = host()
        host.sessionDidConnect(s)
        host.pasteFiles([URL(fileURLWithPath: "/tmp/a")], at: .zero) { _ in }
        fake.offerDone?(true)
        let steps = try #require(fake.keys.last)
        #expect(steps.first?.kind == .pause)
        #expect(steps.first?.milliseconds == 100)
        #expect(steps.dropFirst().map(\.scancode) == RDPKeySequence.ctrlV.map(\.objc).map(\.scancode))
    }

    @Test func aRefusedOfferClicksAndTypesNothing() {
        let (host, s) = host()
        host.sessionDidConnect(s)
        fake.dropHandler?([URL(fileURLWithPath: "/tmp/a")], .zero)
        fake.offerDone?(false)
        #expect(fake.calls == ["start", "offer"])
        #expect(host.notch.notice == "Couldn't paste the files.")
    }

    @Test func aSessionEndingBeforeTheAnswerClicksAndTypesNothing() {
        let (host, s) = host()
        host.sessionDidConnect(s)
        fake.dropHandler?([URL(fileURLWithPath: "/tmp/a")], .zero)
        host.session(s, didDisconnectWithErrorName: "ERRINFO_IDLE_TIMEOUT")
        fake.offerDone?(true) // accepted just before the end, and queued on main behind it
        #expect(fake.calls == ["start", "offer"])
        #expect(host.notch.notice == "Couldn't paste the files.")
    }

    @Test func aHeldCommandIsSpentByAShortcutOrANotchButton() {
        let (host, _) = host()
        host.noteCommandUsed() // a hidden shortcut
        #expect(fake.commandUsed == 1)
        host.notch.togglePin() // every notch action ends in restoreFocus, so a ⌘-click is covered
        #expect(fake.commandUsed == 2)
    }

    @Test func clipboardOffThenReconnectThenOnEnablesItAgain() {
        let (host, s) = host()
        host.sessionDidConnect(s)
        fake.clipboardChannelLoaded = true
        host.notch.toggleClipboard() // off, live
        #expect(!fake.clipboardEnabled)
        fake.clipboardChannelLoaded = false // off in the config: the reconnect comes back without the channel
        host.notch.reconnect()
        #expect(!fake.clipboardEnabled)
        host.notch.toggleClipboard() // on: only a reconnect can load the channel
        #expect(fake.calls.last == "reconnect")
        #expect(fake.clipboardEnabled)
    }

    @Test func aRetryAgreesWithTheConfigAboutTheClipboard() async {
        let (host, s) = host(tries: 1)
        host.sessionDidConnect(s)
        host.setClipboardSync(false)
        fake.clipboardEnabled = true // whatever it holds, the retry puts it right
        host.session(s, didDisconnectWithErrorName: "ERRCONNECT_CONNECT_TRANSPORT_FAILED")
        await host.retry?.value
        #expect(!fake.clipboardEnabled)
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
