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
    func session(_ s: XPRDPSession, requestPasswordForUser user: String, host: String, completion: @escaping (String?) -> Void) {
        calls.append("password"); completion(nil)
    }
    func session(_ s: XPRDPSession, didDisconnectWithErrorName errorName: String?) { calls.append("disconnect") }
    func sessionDidConnect(_ s: XPRDPSession) { calls.append("connect") }
}

/// Nothing here connects: `prepare` builds the context and applies settings without a client thread.
struct XPRDPSessionTests {
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
