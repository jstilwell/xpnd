import Foundation
import Observation

/// User settings, kept in UserDefaults. Code reads them where they're used, so changes apply at once.
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let expansionEnabled = "expansionEnabled"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var expansionEnabled: Bool { didSet { defaults.set(expansionEnabled, forKey: Key.expansionEnabled) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [Key.expansionEnabled: true])
        expansionEnabled = defaults.bool(forKey: Key.expansionEnabled)
    }
}
