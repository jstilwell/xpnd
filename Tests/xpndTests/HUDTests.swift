import Testing
@testable import xpnd

struct HUDTests {
    /// Three seconds is enough for "Password copied", not for two sentences about a broken file.
    @Test func aLongerMessageStaysLonger() {
        #expect(HUD.duration(for: "Sudo password copied") == 3)
        let long = "xpnd couldn't read snippets.yaml, so snippets are paused (connection strings still work). Fix the file and it reloads automatically."
        #expect(HUD.duration(for: long) > 7)
        #expect(HUD.duration(for: String(repeating: "x", count: 5000)) == 12)
    }
}
