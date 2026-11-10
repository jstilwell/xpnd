import AppKit
import Foundation
import Testing
@testable import xpnd
import xpndRDP

@MainActor private final class FakeDelegate: NSObject, XPRDPSessionDelegate {
    var calls: [String] = []
    func session(_ s: XPRDPSession, decideCertificate c: XPRDPCertificate, completion: @escaping (Bool) -> Void) {
        calls.append("certificate"); completion(false)
    }
    func session(_ s: XPRDPSession, requestPasswordForUser user: String, domain: String, host: String,
                 completion: @escaping (String, String, String?) -> Void) {
        calls.append("password"); completion("", "", nil)
    }
    func session(_ s: XPRDPSession, didDisconnectWithErrorName errorName: String?) { calls.append("disconnect") }
    func sessionDidConnect(_ s: XPRDPSession) { calls.append("connect") }
}

/// Nothing here connects: `prepare` builds the context and applies settings without a client thread.
struct XPRDPSessionTests {
    /// Unclipped, a view's dirty rect reaches the top of the window, and the black fill covers the tab bar.
    @MainActor @Test func theDesktopNeverDrawsOutsideItsTab() {
        let s = XPRDPSession(settings: [], password: "", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.view.clipsToBounds)
        s.stop()
    }

    @MainActor @Test func settingsAreAppliedByName() {
        let s = XPRDPSession(settings: [["FreeRDP_ServerHostname", "win.example"], ["FreeRDP_NlaSecurity", "FALSE"]],
                             password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(s.stringSettingNamed("FreeRDP_ServerHostname") == "win.example")
        #expect(!s.boolSettingNamed("FreeRDP_NlaSecurity"))
        s.stop()
    }

    @MainActor @Test func passwordsReachTheSettings() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: "g", delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(s.stringSettingNamed("FreeRDP_Password") == "p")
        #expect(s.stringSettingNamed("FreeRDP_GatewayPassword") == "g")
        s.stop()
    }

    @MainActor @Test func emptyPasswordLeavesFreeRDPToAsk() {
        // FreeRDP only calls AuthenticateEx when the password is unset, not when it is "".
        let s = XPRDPSession(settings: [], password: "", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(s.stringSettingNamed("FreeRDP_Password") == nil)
        s.stop()
    }

    @MainActor @Test func forgetPasswordLeavesFreeRDPToAskAgain() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: "g", delegate: FakeDelegate())
        #expect(s.prepare())
        s.forgetPassword()
        #expect(s.stringSettingNamed("FreeRDP_Password") == nil)
        // A gateway with its own credential too: its refusal is also ACCESS_DENIED.
        #expect(s.stringSettingNamed("FreeRDP_GatewayPassword") == nil)
        s.stop()
        // A fresh context, as reconnect makes, gets no password either.
        let fresh = XPRDPSession(settings: [], password: "p", gatewayPassword: "g", delegate: FakeDelegate())
        fresh.forgetPassword()
        #expect(fresh.prepare())
        #expect(fresh.stringSettingNamed("FreeRDP_Password") == nil)
        #expect(fresh.stringSettingNamed("FreeRDP_GatewayPassword") == nil)
        fresh.stop()
    }

    @MainActor @Test func forgetPasswordForgetsASameCredentialsGatewayToo() {
        // FreeRDP would copy the gateway's password back to the login and send it again.
        let same = XPRDPSession(settings: [["FreeRDP_GatewayEnabled", "TRUE"], ["FreeRDP_GatewayUseSameCredentials", "TRUE"]],
                                password: "p", gatewayPassword: "p", delegate: FakeDelegate())
        #expect(same.prepare())
        same.forgetPassword()
        #expect(same.stringSettingNamed("FreeRDP_Password") == nil)
        #expect(same.stringSettingNamed("FreeRDP_GatewayPassword") == nil)
        same.stop()
    }

    @MainActor @Test func unknownSettingNameFailsPrepare() {
        let s = XPRDPSession(settings: [["FreeRDP_NoSuchSetting", "1"]], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(!s.prepare())
        let bad = XPRDPSession(settings: [["FreeRDP_NlaSecurity", "maybe"]], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(!bad.prepare())
    }

    @MainActor @Test func reconnectWithSettingsReplacesThem() {
        let delegate = FakeDelegate()
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: delegate)
        s.reconnect(withSettings: [["FreeRDP_NoSuchSetting", "1"]]) // the new settings are what the restart applies, and it fails on them
        #expect(delegate.calls == ["disconnect"])
        s.stop()
    }

    @MainActor @Test func settingsReadBackOnlyForTheirType() {
        let s = XPRDPSession(settings: [["FreeRDP_ServerHostname", "win.example"]], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(s.stringSettingNamed("FreeRDP_NlaSecurity") == nil)
        #expect(s.stringSettingNamed("FreeRDP_NoSuchSetting") == nil)
        #expect(!s.boolSettingNamed("FreeRDP_ServerHostname"))
        s.stop()
    }

    // FreeRDP error codes: class << 16 | type (error.h); ERRINFO class 1, CONNECT class 2.
    static let connectFailed: UInt32 = 2 << 16 | 0x06, tlsConnectFailed: UInt32 = 2 << 16 | 0x08
    static let logoffByUser: UInt32 = 1 << 16 | 0x0C
    // LogonErrorInfo values (settings_types.h); the type of a failure is an NTSTATUS.
    static let badPassword: UInt32 = 0, statusLogonFailure: UInt32 = 0xC000_006D
    static let sessionBusy: UInt32 = 0xFFFF_FFF8, sessionContinue: UInt32 = 0xFFFF_FFFE

    @MainActor @Test func disconnectNamesFollowFreeRDPsErrors() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.disconnectErrorName(forCode: 0) == nil)
        #expect(s.disconnectErrorName(forCode: Self.logoffByUser) == nil)
        #expect(s.disconnectErrorName(forCode: Self.connectFailed) == "ERRCONNECT_CONNECT_FAILED")
        #expect(s.disconnectErrorName(forCode: Self.tlsConnectFailed) == "ERRCONNECT_TLS_CONNECT_FAILED")
    }

    @MainActor @Test func aLogonFailureNamesAGenericDisconnect() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        s.noteLogonErrorData(Self.badPassword, type: Self.statusLogonFailure)
        #expect(s.disconnectErrorName(forCode: 0) == "ERRCONNECT_LOGON_FAILURE")
        #expect(s.disconnectErrorName(forCode: Self.connectFailed) == "ERRCONNECT_LOGON_FAILURE")
        #expect(s.disconnectErrorName(forCode: Self.tlsConnectFailed) == "ERRCONNECT_TLS_CONNECT_FAILED")
    }

    @MainActor @Test func aDeclinedCertificateNamesItsTLSFailure() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        s.noteCertificateTrusted(false)
        #expect(s.disconnectErrorName(forCode: Self.tlsConnectFailed) == XPRDPErrorCertificateRejected)
        #expect(s.disconnectErrorName(forCode: Self.connectFailed) == "ERRCONNECT_CONNECT_FAILED")
        s.noteCertificateTrusted(true)
        #expect(s.disconnectErrorName(forCode: Self.tlsConnectFailed) == "ERRCONNECT_TLS_CONNECT_FAILED")
    }

    @MainActor @Test func serverSideNamesAreTheOnesRDPErrorTextKnows() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        let otherConnection = s.disconnectErrorName(forCode: 1 << 16 | 0x05)
        #expect(otherConnection == "ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION")
        #expect(RDPErrorText.reason(forErrorName: otherConnection) == "another client took over the session")
        let rpcLogoff = s.disconnectErrorName(forCode: 1 << 16 | 0x02)
        #expect(rpcLogoff == "ERRINFO_RPC_INITIATED_LOGOFF" && RDPErrorText.isClean(rpcLogoff))
    }

    @MainActor @Test func sessionMessagesAreNotLogonFailures() {
        // For LOGON_MSG_* types `data` is a session id, and session 0 equals LOGON_FAILED_BAD_PASSWORD.
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        s.noteLogonErrorData(0, type: Self.sessionBusy)
        #expect(s.disconnectErrorName(forCode: 0) == nil)
    }

    @MainActor @Test func continuingPastTheLogonScreenClearsTheFailure() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        s.noteLogonErrorData(Self.badPassword, type: Self.statusLogonFailure)
        s.noteLogonErrorData(1, type: Self.sessionContinue)
        #expect(s.disconnectErrorName(forCode: 0) == nil)
    }

    @Test func aWideDesktopIsLetterboxedTopAndBottom() {
        let r = XPRDPFitRect(desktop: CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(r == CGRect(x: 0, y: 50, width: 1000, height: 500))
    }

    @Test func aTallDesktopIsLetterboxedLeftAndRight() {
        let r = XPRDPFitRect(desktop: CGSize(width: 1280, height: 1024), in: CGRect(x: 10, y: 0, width: 1000, height: 400))
        #expect(r == CGRect(x: 260, y: 0, width: 500, height: 400))
    }

    @Test func anEmptyDesktopFillsTheBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(XPRDPFitRect(desktop: .zero, in: bounds) == bounds)
        #expect(XPRDPFitRect(desktop: CGSize(width: 1600, height: 1200), in: bounds) == bounds)  // same aspect: no letterbox
    }

    @Test func clipboardFilterHidesConcealedItems() {
        #expect(!XPRDPClipboardFilter.shouldOfferPasteboardTypes(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(!XPRDPClipboardFilter.shouldOfferPasteboardTypes(["com.jessestilwell.xpnd.secret"]))
        #expect(XPRDPClipboardFilter.shouldOfferPasteboardTypes(["public.utf8-plain-text"]))
        #expect(XPRDPClipboardFilter.shouldOfferPasteboardTypes([]))
    }

    @Test func clipboardFilterSetsAnExpansionAside() {
        // A snippet's paste sits on the pasteboard for a moment, marked transient: it is neither offered nor
        // a reason to withdraw what is on offer. A password is transient too, and that one is withdrawn.
        let transient = "org.nspasteboard.TransientType"
        #expect(XPRDPClipboardFilter.shouldIgnorePasteboardTypes(["public.utf8-plain-text", transient]))
        #expect(!XPRDPClipboardFilter.shouldIgnorePasteboardTypes(["public.utf8-plain-text"]))
        #expect(!XPRDPClipboardFilter.shouldIgnorePasteboardTypes(["public.utf8-plain-text", transient, "org.nspasteboard.ConcealedType"]))
    }

    @MainActor @Test func clipboardFilterKnowsSecretClipboardsTag() {
        // SecretClipboard tags each copy "<prefix>.<UUID>"; the filter must match that shape.
        #expect(!XPRDPClipboardFilter.shouldOfferPasteboardTypes(["public.utf8-plain-text", "\(SecretClipboard.secretTypePrefix).\(UUID().uuidString)"]))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        SecretClipboard.copy("hunter2", to: pasteboard, clearAfter: .seconds(60)).cancel()
        #expect(!XPRDPClipboardFilter.shouldOfferPasteboardTypes((pasteboard.types ?? []).map(\.rawValue)))
    }

    @MainActor @Test func clipboardAnnouncesTextFilesOrNothing() {
        let formats = XPRDPClipboard.formatsToAnnounce(forPasteboardTypes:)
        #expect(formats(["public.utf8-plain-text"]) == .text)
        #expect(formats(["public.file-url", "public.utf8-plain-text"]) == [.text, .files])  // a Finder copy
        #expect(formats(["public.file-url"]) == .files)
        #expect(formats(["NSFilenamesPboardType"]) == .files)
        #expect(formats(["public.png"]).isEmpty)
        #expect(formats([]).isEmpty)
        // Concealed or xpnd-secret: never offered, files or not.
        #expect(formats(["public.file-url", "org.nspasteboard.ConcealedType"]).isEmpty)
        #expect(formats(["public.utf8-plain-text", "\(SecretClipboard.secretTypePrefix).\(UUID().uuidString)"]).isEmpty)
    }

    @MainActor @Test func resizeCoalescerFiresOnceWithLastSize() async throws {
        var sizes: [CGSize] = []
        // An idle interval well past any moment another suite holds the main thread between two notes.
        let c = XPRDPResizeCoalescer(idleInterval: 0.5) { sizes.append($0) }
        c.noteSize(CGSize(width: 100, height: 100))
        try await Task.sleep(for: .milliseconds(20))
        c.noteSize(CGSize(width: 200, height: 150))
        try await Task.sleep(for: .milliseconds(20))
        c.noteSize(CGSize(width: 300, height: 250))
        #expect(sizes.isEmpty)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(sizes == [CGSize(width: 300, height: 250)])
    }

    // MARK: The notch's additions

    @MainActor @Test func driveDeviceIsAddedToSettings() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, driveName: "xpnd", drivePath: "/tmp/x", delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(s.boolSettingNamed("FreeRDP_DeviceRedirection"))
        #expect(s.deviceCount() == 1)
        s.stop()
    }

    @MainActor @Test func noDriveMeansNoDevice() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(!s.boolSettingNamed("FreeRDP_DeviceRedirection"))
        #expect(s.deviceCount() == 0)
        s.stop()
    }

    /// `reconnect` is `stop`'s teardown then `start`'s `prepare`: a new context each time, never a second device on one.
    @MainActor @Test func theDriveIsAddedOncePerContext() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, driveName: "xpnd", drivePath: "/tmp/x", delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(s.prepare())
        #expect(s.deviceCount() == 1)
        s.stop()
        #expect(s.prepare())
        #expect(s.deviceCount() == 1)
        s.stop()
    }

    /// freerdp_client_add_drive skips a missing folder, or redirects `./xpnd` in its place if that exists.
    @MainActor @Test func theDriveIsAlwaysTheFolderGiven() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, driveName: "xpnd", drivePath: "/nonexistent/drop", delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(s.drivePath(at: 0) == "/nonexistent/drop")
        s.stop()
    }

    @MainActor @Test func anOverlongFolderFailsRatherThanBeingCutShort() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, driveName: "xpnd",
                             drivePath: "/" + String(repeating: "x", count: 300), delegate: FakeDelegate())
        #expect(!s.prepare())
    }

    @MainActor @Test func clipboardDisabledIgnoresEverything() {
        let c = XPRDPClipboard()
        c.offerText("before", fileURIList: nil)
        #expect(c.lastAnnouncedFormats == .text)
        #expect(c.formatsToAnnounceNow(forPasteboardTypes: ["public.utf8-plain-text"]) == .text)
        c.enabled = false
        #expect(c.lastAnnouncedFormats.isEmpty)  // what was on offer goes too
        #expect(c.formatsToAnnounceNow(forPasteboardTypes: ["public.utf8-plain-text"]).isEmpty)
        c.offerText("after", fileURIList: Data("file:///a\r\n".utf8))
        #expect(c.lastAnnouncedFormats.isEmpty)
        c.enabled = true
        c.offerText("again", fileURIList: nil)
        #expect(c.lastAnnouncedFormats == .text)
    }

    @MainActor @Test func aFileOfferWithNoChannelIsRefused() async {
        let c = XPRDPClipboard()
        #expect(await !c.offerFileURLs([URL(fileURLWithPath: "/tmp/a.txt")]))  // no channel here
        #expect(c.lastAnnouncedFormats.isEmpty)
    }

    @Test func aFileOfferIsTheURIListAFinderCopyGives() throws {
        let list = try #require(XPRDPClipboard.fileURIList(for: [
            URL(fileURLWithPath: "/tmp/a b.txt"), URL(string: "https://example.com/x")!, URL(fileURLWithPath: "/tmp/é.txt"),
        ]))
        #expect(String(decoding: list, as: UTF8.self) == "file:///tmp/a%20b.txt\r\nfile:///tmp/e%CC%81.txt\r\n")
        #expect(XPRDPClipboard.fileURIList(for: [URL(string: "https://example.com/x")!]) == nil)
        #expect(XPRDPClipboard.fileURIList(for: []) == nil)
    }

    @Test func keyStepBridging() {
        let down = RDPKeyStep.scancode(0x014F, down: true).objc
        #expect(down.kind == .scancode && down.scancode == 0x014F && down.down)
        #expect(!RDPKeyStep.scancode(0x1D, down: false).objc.down)
        let text = RDPKeyStep.text("a").objc
        #expect(text.kind == .text && text.text == "a")
        let pause = RDPKeyStep.pause(ms: 300).objc
        #expect(pause.kind == .pause && pause.milliseconds == 300)
    }

    /// What a player sent, and a switch for "the session is connected".
    @MainActor private final class KeyLog {
        var sent: [String] = []
        var connected = true
        lazy var player = XPRDPKeyPlayer(
            scancode: { [unowned self] code, down in sent.append("\(down ? "down" : "up") \(code)") },
            text: { [unowned self] in sent.append("text \($0)") },
            canSend: { [unowned self] in connected })
    }

    private func steps(_ steps: RDPKeyStep...) -> [XPRDPKeyStep] { steps.map(\.objc) }

    @MainActor @Test func aSequenceRunsInOrderAndContinuesAfterAPause() async throws {
        let log = KeyLog()
        log.player.play(steps(.scancode(1, down: true), .scancode(1, down: false), .pause(ms: 20), .text("x")))
        #expect(log.sent == ["down 1", "up 1"])  // main isn't blocked: the rest comes later
        log.player.play(steps(.text("y")))  // queued behind the pause
        #expect(log.sent == ["down 1", "up 1"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.sent == ["down 1", "up 1", "text x", "text y"])
    }

    @MainActor @Test func aSessionEndingDuringAPauseSendsNothingMore() async throws {
        let log = KeyLog()
        log.player.play(steps(.scancode(1, down: true), .pause(ms: 20), .scancode(2, down: true), .scancode(2, down: false), .scancode(1, down: false)))
        log.connected = false
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.sent == ["down 1"])
        log.connected = true
        log.player.play(steps(.text("z")))  // the held key died with the connection; nothing stale comes back
        #expect(log.sent == ["down 1", "text z"])
    }

    @MainActor @Test func cancelDuringAPauseReleasesHeldKeysAndDropsTheRest() async throws {
        let log = KeyLog()
        log.player.play(steps(.scancode(1, down: true), .scancode(2, down: true), .pause(ms: 20), .text("x")))
        log.player.cancel()
        #expect(log.sent == ["down 1", "down 2", "up 2", "up 1"])
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.sent.count == 4)
    }

    @MainActor @Test func aSequenceThatEndsHoldingAKeyLetsItGo() {
        let log = KeyLog()
        log.player.play(steps(.scancode(1, down: true)))
        #expect(log.sent == ["down 1", "up 1"])
    }

    @MainActor @Test func aFreedPlayerNeverContinues() async throws {
        let log = KeyLog()
        var player: XPRDPKeyPlayer? = XPRDPKeyPlayer(
            scancode: { _, _ in }, text: { log.sent.append($0) }, canSend: { true })
        player?.play(steps(.pause(ms: 20), .text("x")))
        player = nil
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.sent.isEmpty)
    }

    @MainActor @Test func nothingHappensOnASessionThatIsNotConnected() async {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.prepare())
        s.sendKeySequence(steps(.scancode(0x1D, down: true), .pause(ms: 10), .text("x")))
        s.sendLeftClick(atViewPoint: NSPoint(x: 10, y: 10))
        #expect(await !s.offerFiles(forPaste: [URL(fileURLWithPath: "/tmp/a.txt")]))
        #expect(!s.requestDesktopFit())
        #expect(!s.requestDesktopWidth(1280, height: 720))
        #expect(!s.clipboardChannelLoaded)
        s.stop()
    }

    private final class FakeDrag: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        @MainActor init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation { get { .none } set {} }
        var animatesToDestination: Bool { get { false } set {} }
        var numberOfValidItemsForDrop: Int { get { 1 } set {} }
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    @MainActor @Test func theDesktopTakesFileDropsOnlyWhileConnected() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.view.registeredDraggedTypes.contains(.fileURL))
        var dropped = false
        s.dropHandler = { _, _ in dropped = true }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        let drag = FakeDrag(pasteboard)
        #expect(s.view.draggingEntered(drag) == [])
        #expect(s.view.draggingUpdated(drag) == [])
        #expect(s.view.performDragOperation(drag) == false)
        #expect(!dropped)
    }

    @MainActor @Test func aDropCarriesFileURLsOnly() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let file = URL(fileURLWithPath: "/tmp/a.txt")
        pasteboard.writeObjects([URL(string: "https://example.com/x")! as NSURL, file as NSURL])
        #expect(XPRDPClipboard.fileURLs(on: pasteboard) == [file])
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(string: "https://example.com/x")! as NSURL])
        #expect(XPRDPClipboard.fileURLs(on: pasteboard).isEmpty)
    }

    @MainActor @Test func connectionInfoReadsTheSettings() {
        let s = XPRDPSession(settings: [["FreeRDP_DesktopWidth", "1280"], ["FreeRDP_DesktopHeight", "720"],
                                        ["FreeRDP_GatewayEnabled", "TRUE"], ["FreeRDP_GatewayHostname", "gw.example"]],
                             password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.prepare())
        let info = s.connectionInfo
        #expect(info.desktopWidth == 1280 && info.desktopHeight == 720)
        #expect(info.codec == "—")
        #expect(info.latencyMs == nil && info.connectedSince == nil)
        #expect(info.certificateSubject == "" && info.certificateFingerprint == "")
        #expect(info.gatewayHost == "gw.example")
        s.stop()
        #expect(s.connectionInfo.desktopWidth == 0)  // no context: nothing to read, nothing to crash on
    }

    @MainActor @Test func noGatewayIsNil() {
        let s = XPRDPSession(settings: [["FreeRDP_GatewayHostname", "gw.example"]], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.prepare())
        #expect(s.connectionInfo.gatewayHost == nil)
        s.stop()
    }

    @MainActor @Test func theCodecIsTheLastNamedOneSeen() {
        let s = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        // RDPGFX_CODECID_*: uncompressed, CAVIDEO, planar, CAPROGRESSIVE, CAPROGRESSIVE_V2, then ClearCodec.
        for (id, name) in [(0x0000, "bitmap"), (0x0003, "RemoteFX"), (0x000A, "planar"), (0x0009, "progressive"), (0x000D, "progressive")] {
            s.noteGfxCodec(UInt16(id))
            #expect(s.connectionInfo.codec == name)
        }
        s.noteGfxCodec(0x0008)  // ClearCodec paints text between frames of the codec in use
        #expect(s.connectionInfo.codec == "progressive")
    }

    /// A throwaway self-signed certificate, for FreeRDP's known-hosts file; its key was discarded.
    private static let knownHostPEM = """
        -----BEGIN CERTIFICATE-----
        MIIBYjCCAQigAwIBAgIUDs4KosPCJldl7ij4wSwWss+5GqMwCgYIKoZIzj0EAwIw
        FjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwIBcNMjYxMTA1MTkwODQwWhgPMjEyNjEw
        MTIxOTA4NDBaMBYxFDASBgNVBAMMC3dpbi5leGFtcGxlMFkwEwYHKoZIzj0CAQYI
        KoZIzj0DAQcDQgAE/0ZjZPbddlpj8NEvaS2zr6tplIxFCzzyXz3HcsdcTlHDkC4a
        moyJHHF2R+SRiluiBNVz+lkoMk+t61TR83MiS6MyMDAwHQYDVR0OBBYEFLgLWrW0
        vv5DcAKdC6z3RD1lV1SGMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAw
        RQIgKjPtXiXvTIhD95ul1fb3rfRekA1YyIDy6PIxZRqruowCIQCieptpv564Bn5a
        p4JIYarRW15Fh1KuArVEQssQzWDRWg==
        -----END CERTIFICATE-----

        """

    /// The usual case: FreeRDP asks about a certificate once, and later connects find it in known hosts.
    @MainActor @Test func connectionInfoFindsAKnownHostsCertificate() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "xpnd-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "server"), withIntermediateDirectories: true)
        try Data(Self.knownHostPEM.utf8).write(to: dir.appending(path: "server/win.example_3389.pem"))
        let s = XPRDPSession(settings: [["FreeRDP_ConfigPath", dir.path], ["FreeRDP_ServerHostname", "win.example"], ["FreeRDP_ServerPort", "3389"]],
                             password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        #expect(s.prepare())
        let info = s.connectionInfo
        #expect(info.certificateSubject.contains("win.example"))
        #expect(info.certificateFingerprint.lowercased() == "20:c0:f6:d2:cc:0c:da:6d:01:8b:1e:72:14:2b:ab:44:5c:a8:ff:5a:05:4d:92:3b:cf:8c:a4:d9:98:72:5c:bf")
        // Read once per connect: gone from disk, it is still what this connect had; a new context reads again.
        try FileManager.default.removeItem(at: dir.appending(path: "server/win.example_3389.pem"))
        #expect(s.connectionInfo.certificateSubject == info.certificateSubject)
        s.stop()
        #expect(s.prepare())
        #expect(s.connectionInfo.certificateSubject == "")
        s.stop()
    }

    @MainActor @Test func stopBeforeStartReportsNothing() async throws {
        let delegate = FakeDelegate()
        let s = XPRDPSession(settings: [["FreeRDP_ServerHostname", "win.example"]], password: "p", gatewayPassword: nil, delegate: delegate)
        #expect(s.prepare())
        s.stop()
        s.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(delegate.calls.isEmpty)
        #expect(s.stringSettingNamed("FreeRDP_ServerHostname") == nil)  // the context is gone
    }
}
