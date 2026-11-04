import Testing
import SwiftTerm
@testable import xpnd

@MainActor struct LiveTerminalHostTests {
    @Test func environmentAddsTermAndLocaleOnlyWhenMissing() {
        let env = LiveTerminalHost.environment(from: ["HOME": "/u", "LANG": "de_DE.UTF-8"], locale: "en_US")
        #expect(env.contains("TERM=xterm-256color") && env.contains("COLORTERM=truecolor") && env.contains("LANG=de_DE.UTF-8") && env.contains("HOME=/u"))
        #expect(LiveTerminalHost.environment(from: [:], locale: "en_US@rg=gbzzzz").contains("LANG=en_US.UTF-8"))
    }

    @Test func clipboardGuardDeniesRemoteReads() {
        let view = LocalProcessTerminalView(frame: .zero)
        let guarded = ClipboardReadGuard(view)
        #expect(view.terminalDelegate === guarded)
        #expect(guarded.clipboardRead(source: view) == nil)
        // OSC 5522: nil would mean "read the pasteboard", so a read is denied outright.
        #expect(guarded.kittyClipboardCapabilities(source: view).isDisjoint(with: [.standardRead, .primaryRead]))
        #expect(guarded.kittyClipboardRead(source: view, location: .standard, mimeType: "text/plain") == .denied)
        #expect(guarded.kittyClipboardAvailableMimeTypes(source: view, location: .standard) == [])
        let read = KittyClipboardPermissionRequest(
            direction: .read, location: .standard, name: "", mimeTypes: ["text/plain"], canRememberPassword: false)
        guard case .deny = guarded.kittyClipboardRequestPermission(source: view, request: read) else {
            Issue.record("a Kitty read permission request was allowed"); return
        }
    }

    @Test func cursorStyleMapping() {
        var s = BuiltInTerminalSettings.standard
        #expect(s.cursorStyle == .blinkBlock)
        s.cursorBlinks = false; s.cursor = .bar
        #expect(s.cursorStyle == .steadyBar)
    }
}
