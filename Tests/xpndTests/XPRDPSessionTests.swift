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
        let fresh = XPRDPSession(settings: [], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
        fresh.forgetPassword()
        #expect(fresh.prepare())
        #expect(fresh.stringSettingNamed("FreeRDP_Password") == nil)
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
        let c = XPRDPResizeCoalescer(idleInterval: 0.1) { sizes.append($0) }
        c.noteSize(CGSize(width: 100, height: 100))
        try await Task.sleep(for: .milliseconds(20))
        c.noteSize(CGSize(width: 200, height: 150))
        try await Task.sleep(for: .milliseconds(20))
        c.noteSize(CGSize(width: 300, height: 250))
        #expect(sizes.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        #expect(sizes == [CGSize(width: 300, height: 250)])
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
