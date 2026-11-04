import Testing
@testable import xpnd

struct ExpansionTargetingTests {
    @Test func onlyAFocusedTerminalIsExempt() {
        #expect(!ExpansionTargeting.targetsXpnd(keyTargetsProcess: false, terminalFocused: false))
        #expect(!ExpansionTargeting.targetsXpnd(keyTargetsProcess: false, terminalFocused: true))
        #expect(ExpansionTargeting.targetsXpnd(keyTargetsProcess: true, terminalFocused: false))
        #expect(!ExpansionTargeting.targetsXpnd(keyTargetsProcess: true, terminalFocused: true))
    }
}
