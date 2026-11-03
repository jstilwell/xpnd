import AppKit

/// A small click-through panel in the corner of the screen for brief messages. Never show typed
/// keys or snippet text in it.
@MainActor
final class HUD {
    private let panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
    )
    private let background = NSVisualEffectView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideTask: Task<Void, Never>?

    init() {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13)
        label.isSelectable = false
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 420
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        panel.contentView = background
    }

    func show(_ text: String) {
        hideTask?.cancel()
        label.stringValue = text
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize

        // Bottom-right of whichever screen the cursor is on, clear of the Dock.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.minY + 16)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    /// Shows `text`, then hides it after `seconds` unless something newer was shown meanwhile.
    func flash(_ text: String, seconds: Double = 3) {
        show(text)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        panel.orderOut(nil)
    }
}
