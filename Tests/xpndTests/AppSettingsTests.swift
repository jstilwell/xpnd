import AppKit
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

    @Test func onePasswordSettingsPersist() throws {
        let suite = "AppSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.onePasswordPath == nil)
        #expect(settings.onePasswordAccount == nil)
        settings.onePasswordPath = "/opt/op/bin/op"
        settings.onePasswordAccount = "ACCT1"
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.onePasswordPath == "/opt/op/bin/op")
        #expect(reloaded.onePasswordAccount == "ACCT1")
        reloaded.onePasswordPath = nil
        #expect(AppSettings(defaults: defaults).onePasswordPath == nil)
        #expect(AppSettings(defaults: defaults).onePasswordAccount == "ACCT1")
    }

    @Test func sshConnectDefaultsStartOnAndPersist() throws {
        let suite = "AppSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: defaults).sshConnectDefaults)
        AppSettings(defaults: defaults).sshConnectDefaults = false
        #expect(!AppSettings(defaults: defaults).sshConnectDefaults)
    }

    @Test func recentConnectionsPersist() throws {
        let suite = "AppSettingsTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: defaults).recentConnections.isEmpty)
        let ids = [UUID(), UUID()]
        AppSettings(defaults: defaults).recentConnections = ids
        #expect(AppSettings(defaults: defaults).recentConnections == ids)
    }

    @Test func menuKeyEquivalentForLettersSpaceAndFunctionKeys() {
        #expect(Shortcut(keyCode: 8, modifiers: [.command, .control], key: "C").menuKeyEquivalent == "c")
        #expect(Shortcut(keyCode: 49, modifiers: [.command, .control], key: "Space").menuKeyEquivalent == " ")
        #expect(Shortcut(keyCode: 96, modifiers: [.command], key: "F5").menuKeyEquivalent == String(Character(UnicodeScalar(NSF5FunctionKey)!)))
        #expect(Shortcut(keyCode: 123, modifiers: [.command, .option], key: "←").menuKeyEquivalent == String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
    }
}
