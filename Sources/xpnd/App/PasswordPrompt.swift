import AppKit

/// Offers the sudo password in the corner of the screen. The panel never becomes key, so the
/// terminal keeps the keyboard and stays the front app while the user clicks.
@MainActor final class PasswordPrompt: NSObject, PasswordPrompting {
    private static let timeout: Duration = .seconds(60)
    /// Tuning value: clears the HUD, which shows "Password copied" in the same corner at the same time.
    private static let bottomInset: CGFloat = 80

    private let panel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
    )
    private let background = NSVisualEffectView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private var pending: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13)
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 320

        let copy = PanelButton(title: "Copy sudo password", target: self, action: #selector(copyPressed))
        let dismiss = PanelButton(title: "Dismiss", target: self, action: #selector(dismissPressed))
        let buttons = NSStackView(views: [copy, dismiss])
        let stack = NSStackView(views: [label, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    func offerSudo(for name: String) async -> Bool {
        finish(false) // a newer connection replaces an offer still showing
        label.stringValue = "Sudo password for “\(name)”"
        background.layoutSubtreeIfNeeded()
        let size = background.fittingSize

        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return false }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - size.width - 16, y: visible.minY + Self.bottomInset)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()

        return await withCheckedContinuation { continuation in
            pending = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                guard !Task.isCancelled else { return }
                self?.finish(false)
            }
        }
    }

    @objc private func copyPressed() { finish(true) }
    @objc private func dismissPressed() { finish(false) }

    private func finish(_ answer: Bool) {
        timeoutTask?.cancel()
        panel.orderOut(nil)
        pending?.resume(returning: answer)
        pending = nil
    }
}

/// The panel is never key and xpnd is rarely active, so the first click has to count.
private final class PanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
