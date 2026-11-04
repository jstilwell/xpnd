import Foundation

/// How the built-in terminal looks and behaves. A plain value type, stored in UserDefaults as JSON.
struct BuiltInTerminalSettings: Codable, Hashable, Sendable {
    enum Scheme: String, Codable, CaseIterable, Sendable { case system, light, dark }
    enum Cursor: String, Codable, CaseIterable, Sendable { case block, bar, underline }

    /// nil is the system monospaced font.
    var fontName: String?
    var fontSize: Double
    var scheme: Scheme
    var cursor: Cursor
    var cursorBlinks: Bool
    var scrollback: Int

    static let standard = BuiltInTerminalSettings(
        fontName: nil, fontSize: 13, scheme: .system, cursor: .block, cursorBlinks: true, scrollback: 10_000)
}
