import Foundation
import Testing
@testable import xpnd

@MainActor
struct AppSettingsTests {
    @Test func shortcutsPersistIndependently() throws {
        let suite = "AppSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.pickerShortcut == AppSettings.defaultPickerShortcut)
        #expect(settings.connectionLauncherShortcut == AppSettings.defaultConnectionLauncherShortcut)
        settings.connectionLauncherShortcut = nil
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.connectionLauncherShortcut == nil)
        #expect(reloaded.pickerShortcut == AppSettings.defaultPickerShortcut)
        let other = Shortcut(keyCode: 0, modifiers: [.command, .option], key: "A")
        reloaded.pickerShortcut = other
        let again = AppSettings(defaults: defaults)
        #expect(again.pickerShortcut == other)
        #expect(again.connectionLauncherShortcut == nil)
    }
}
