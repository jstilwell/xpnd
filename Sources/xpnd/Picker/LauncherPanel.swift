import AppKit
import SwiftUI

/// The floating, non-activating panel the picker and the quick menu share: centered high on the screen
/// with the mouse, closes when it loses key, remembers the app that was in front.
@MainActor
class LauncherPanel {
    /// How long to wait for the app that was in front to come back before acting in it.
    private static let refocusTimeout: Duration = .seconds(1)

    private let panel = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
    )
    /// The app in front when the panel opened; nil when that was xpnd itself.
    var previousApp: NSRunningApplication?
    var isVisible: Bool { panel.isVisible }
    /// Sees key-downs before the panel's views; return true to swallow one. nil leaves keys to the views.
    var onKeyDown: ((NSEvent) -> Bool)? {
        get { panel.onKeyDown }
        set { panel.onKeyDown = newValue }
    }

    init() {
        panel.onResignKey = { [weak self] in self?.close() }
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func present(_ view: some View) {
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front == .current ? nil : front
        panel.contentView = NSHostingView(rootView: view)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height / 3 - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Brings `previousApp` back to the front, waiting up to 1 s. Returns the frontmost pid afterwards.
    @discardableResult
    func refocusPrevious() async -> pid_t? {
        if let app = previousApp {
            NSApp.yieldActivation(to: app)
            app.activate()
            let deadline = ContinuousClock.now + Self.refocusTimeout
            while NSWorkspace.shared.frontmostApplication != app, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onResignKey: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true { return }
        super.sendEvent(event)
    }

    // Clicking into another app doesn't deactivate xpnd (the panel is non-activating), so close here.
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
