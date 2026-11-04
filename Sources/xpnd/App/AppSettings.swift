import Foundation
import Observation

/// User settings, kept in UserDefaults. Code reads them where they're used, so changes apply at once.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let expansionEnabled = "expansionEnabled"
        static let pickerShortcut = "pickerShortcut"
        static let connectionLauncherShortcut = "connectionLauncherShortcut"
        static let terminalSettings = "terminalSettings"
        static let builtInTerminal = "builtInTerminal"
        static let onePasswordPath = "onePasswordPath"
        static let onePasswordAccount = "onePasswordAccount"
        static let typesKeystrokes = "typesKeystrokes"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var expansionEnabled: Bool { didSet { defaults.set(expansionEnabled, forKey: Key.expansionEnabled) } }

    /// Control+Option+Command+Space unless changed; nil turns the picker hotkey off.
    static let defaultPickerShortcut = Shortcut(keyCode: 49, modifiers: [.control, .option, .command], key: "Space")

    var pickerShortcut: Shortcut? {
        didSet { defaults.set(try? JSONEncoder().encode(pickerShortcut), forKey: Key.pickerShortcut) }
    }

    /// Control+Option+Command+C unless changed; nil turns the connection launcher hotkey off.
    static let defaultConnectionLauncherShortcut = Shortcut(keyCode: 8, modifiers: [.control, .option, .command], key: "C")

    var connectionLauncherShortcut: Shortcut? {
        didSet { defaults.set(try? JSONEncoder().encode(connectionLauncherShortcut), forKey: Key.connectionLauncherShortcut) }
    }

    var terminal: TerminalSettings {
        didSet { defaults.set(try? JSONEncoder().encode(terminal), forKey: Key.terminalSettings) }
    }

    var builtInTerminal: BuiltInTerminalSettings {
        didSet { defaults.set(try? JSONEncoder().encode(builtInTerminal), forKey: Key.builtInTerminal) }
    }

    /// Where `op` is, when it isn't in Homebrew's or /usr/local's bin; nil looks only there.
    var onePasswordPath: String? { didSet { defaults.set(onePasswordPath, forKey: Key.onePasswordPath) } }

    /// The 1Password account id to search; nil uses the first signed-in one.
    var onePasswordAccount: String? { didSet { defaults.set(onePasswordAccount, forKey: Key.onePasswordAccount) } }

    /// Type every snippet as keystrokes instead of pasting; off, only remote-desktop apps get typed.
    var typesKeystrokes: Bool { didSet { defaults.set(typesKeystrokes, forKey: Key.typesKeystrokes) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.expansionEnabled: true])
        expansionEnabled = defaults.bool(forKey: Key.expansionEnabled)
        if let data = defaults.data(forKey: Key.pickerShortcut) {
            pickerShortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
        } else {
            pickerShortcut = Self.defaultPickerShortcut
        }
        if let data = defaults.data(forKey: Key.connectionLauncherShortcut) {
            connectionLauncherShortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
        } else {
            connectionLauncherShortcut = Self.defaultConnectionLauncherShortcut
        }
        terminal = defaults.data(forKey: Key.terminalSettings).flatMap { try? JSONDecoder().decode(TerminalSettings.self, from: $0) } ?? .standard
        builtInTerminal = defaults.data(forKey: Key.builtInTerminal).flatMap { try? JSONDecoder().decode(BuiltInTerminalSettings.self, from: $0) } ?? .standard
        onePasswordPath = defaults.string(forKey: Key.onePasswordPath)
        onePasswordAccount = defaults.string(forKey: Key.onePasswordAccount)
        typesKeystrokes = defaults.bool(forKey: Key.typesKeystrokes)
    }
}
