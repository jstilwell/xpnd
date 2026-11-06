import AppKit
import Testing
import xpndRDP

struct XPRDPCursorTests {
    private func bitmap(_ side: Int) throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0))
    }

    @Test func aRetinaDesktopHalvesTheCursor() {
        // Fit with Retina on: the desktop is in pixels, the tab in points.
        let scale = XPRDPCursorScale(desktop: CGSize(width: 2000, height: 1200), drawn: CGRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(scale == 0.5)
    }

    @Test func aDesktopDrawnAtItsOwnSizeLeavesTheCursorAlone() {
        #expect(XPRDPCursorScale(desktop: CGSize(width: 1000, height: 600), drawn: CGRect(x: 0, y: 0, width: 1000, height: 600)) == 1)
    }

    @Test func aFixedDesktopFollowsItsLetterboxedSize() {
        let scale = XPRDPCursorScale(desktop: CGSize(width: 1920, height: 1080), drawn: CGRect(x: 40, y: 0, width: 960, height: 540))
        #expect(scale == 0.5)
    }

    @Test func anEmptySizeLeavesTheCursorAlone() {
        #expect(XPRDPCursorScale(desktop: .zero, drawn: CGRect(x: 0, y: 0, width: 1000, height: 600)) == 1)
        #expect(XPRDPCursorScale(desktop: CGSize(width: 1000, height: 600), drawn: .zero) == 1)
    }

    /// Smaller in points with every pixel kept, so it stays sharp, and the click point moves with the image.
    @Test func scalingKeepsThePixelsAndMovesTheHotSpot() throws {
        let cursor = XPRDPScaledCursor(try bitmap(64), NSPoint(x: 20, y: 10), 0.5)
        #expect(cursor.image.size == NSSize(width: 32, height: 32))
        #expect(cursor.hotSpot == NSPoint(x: 10, y: 5))
        let rep = try #require(cursor.image.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == 64)
    }

    /// FreeRDP frees a pointer's pixels with the pointer, while the view still holds the cursor.
    @Test func theCopyOwnsItsPixels() throws {
        let side = 8
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: side * side * 4)
        defer { pixels.deallocate() }
        pixels.initialize(repeating: 255, count: side * side * 4)
        var planes: UnsafeMutablePointer<UInt8>? = pixels
        let source = try #require(withUnsafeMutablePointer(to: &planes) {
            NSBitmapImageRep(bitmapDataPlanes: $0, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 0)
        })
        let image = NSImage(size: source.size)
        image.addRepresentation(source)
        let original = NSCursor(image: image, hotSpot: .zero)
        let copy = try #require(XPRDPOwnedBitmap(original))
        pixels.update(repeating: 0, count: side * side * 4)
        #expect(copy.pixelsWide == side)
        #expect(copy.colorAt(x: 3, y: 3)?.alphaComponent == 1)
    }
}
