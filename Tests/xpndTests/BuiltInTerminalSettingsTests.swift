import Foundation
import Testing
@testable import xpnd

struct BuiltInTerminalSettingsTests {
    @Test func standardDefaults() {
        let s = BuiltInTerminalSettings.standard
        #expect(s.fontName == nil && s.fontSize == 13 && s.scheme == .system && s.cursor == .block && s.cursorBlinks && s.scrollback == 10_000)
    }

    @Test func roundTripsThroughJSON() throws {
        var s = BuiltInTerminalSettings.standard
        s.fontName = "Menlo"; s.scheme = .dark; s.cursor = .bar; s.cursorBlinks = false; s.scrollback = 2000
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(BuiltInTerminalSettings.self, from: data) == s)
    }

    @MainActor @Test func appSettingsPersists() {
        let defaults = UserDefaults(suiteName: "BuiltInTerminalSettingsTests-\(UUID())")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.builtInTerminal == .standard)
        settings.builtInTerminal.fontSize = 15
        #expect(AppSettings(defaults: defaults).builtInTerminal.fontSize == 15)
    }
}
