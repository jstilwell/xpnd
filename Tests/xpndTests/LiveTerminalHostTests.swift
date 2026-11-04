import Testing
import SwiftTerm
@testable import xpnd

@MainActor struct LiveTerminalHostTests {
    @Test func environmentAddsTermAndLocaleOnlyWhenMissing() {
        let env = LiveTerminalHost.environment(from: ["HOME": "/u", "LANG": "de_DE.UTF-8"], locale: "en_US")
        #expect(env.contains("TERM=xterm-256color") && env.contains("COLORTERM=truecolor") && env.contains("LANG=de_DE.UTF-8") && env.contains("HOME=/u"))
        #expect(LiveTerminalHost.environment(from: [:], locale: "en_US@rg=gbzzzz").contains("LANG=en_US.UTF-8"))
    }

    @Test func clipboardGuardDeniesOSC52Reads() {
        let view = LocalProcessTerminalView(frame: .zero)
        let guarded = ClipboardReadGuard(view)
        #expect(view.terminalDelegate === guarded)
        #expect(guarded.clipboardRead(source: view) == nil)
    }

    @Test func cursorStyleMapping() {
        var s = BuiltInTerminalSettings.standard
        #expect(s.cursorStyle == .blinkBlock)
        s.cursorBlinks = false; s.cursor = .bar
        #expect(s.cursorStyle == .steadyBar)
    }
}
