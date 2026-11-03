import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    private(set) var menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "xpnd")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.menu = menu
        rebuildMenu()
        log.info("xpnd launched")
    }

    /// Later tasks add their items here, above Quit.
    func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(withTitle: "Quit xpnd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}
