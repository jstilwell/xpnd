import Foundation

enum TerminalPreset: String, Codable, CaseIterable, Sendable {
    case terminal, iterm2, ghostty

    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm2: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        }
    }

    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm2: "iTerm2"
        case .ghostty: "Ghostty"
        }
    }

    /// Terminal would need System Events keystrokes on the macOS versions xpnd supports, and
    /// Ghostty has no command-line way on macOS: `+new-tab` is "not supported on this platform".
    var supportsTabs: Bool { self == .iterm2 }
}

enum NoTerminalAction: Codable, Hashable, Sendable {
    case preset(TerminalPreset, newTab: Bool)
    case custom(template: String)
}

struct TerminalSettings: Codable, Hashable, Sendable {
    var terminalBundleIDs: [String]
    var whenNoTerminal: NoTerminalAction

    /// Warp is only detected: it has no preset, so reaching it from outside takes a custom command.
    static let standard = TerminalSettings(
        terminalBundleIDs: TerminalPreset.allCases.map(\.bundleID) + ["dev.warp.Warp-Stable"],
        whenNoTerminal: .preset(.terminal, newTab: false))
}
