import AppKit
import SwiftTerm

extension BuiltInTerminalSettings {
    var nsFont: NSFont {
        let size = CGFloat(fontSize)
        return fontName.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) } ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var cursorStyle: CursorStyle {
        switch (cursor, cursorBlinks) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        }
    }

    func colors(dark: Bool) -> (foreground: NSColor, background: NSColor) {
        dark ? (.white, .black) : (.black, .white)
    }

    /// `.system` follows the app's current appearance.
    @MainActor var colors: (foreground: NSColor, background: NSColor) {
        switch scheme {
        case .light: colors(dark: false)
        case .dark: colors(dark: true)
        case .system: colors(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }
}
