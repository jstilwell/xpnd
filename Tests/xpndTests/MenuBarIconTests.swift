import AppKit
import Testing
@testable import xpnd

struct MenuBarIconTests {
    @MainActor @Test func isATemplateOnTheMenuBarGrid() {
        let image = MenuBarIcon.image()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "xpnd")
    }

    /// The prompt sits left of the lines, and the corners stay empty: a blank or misplaced drawing fails here.
    @MainActor @Test func drawsThePromptAndTheLines() throws {
        let image = MenuBarIcon.image()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        func ink(_ x: Int, _ y: Int) -> Bool { (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
        #expect(ink(14, 18)) // the prompt's point, at (7, 9) on the grid
        #expect(ink(24, 18)) // the middle line
        #expect(ink(28, 27)) // the longest line, at the bottom: flipped, it would be at the top
        #expect(!ink(28, 9)) // the shortest line stops well before this
        #expect(!ink(0, 0))
    }
}
