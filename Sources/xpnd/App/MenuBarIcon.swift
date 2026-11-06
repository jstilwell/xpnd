import AppKit

/// The app icon's mark on the 18 pt grid: a prompt and three growing lines. A template, so macOS colours it for
/// the menu bar. Drawn here rather than shipped as a file, so it is sharp at any scale.
enum MenuBarIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 2.5, y: 4.5))
            path.line(to: NSPoint(x: 7, y: 9))
            path.line(to: NSPoint(x: 2.5, y: 13.5))
            for (y, end) in [(4.5, 11.5), (9, 13.5), (13.5, 15.5)] {
                path.move(to: NSPoint(x: 10, y: y))
                path.line(to: NSPoint(x: end, y: y))
            }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "xpnd"
        return image
    }
}
