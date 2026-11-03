import AppKit
import SwiftUI

/// The first thing shown without Accessibility and Input Monitoring access: what xpnd does, and how
/// to let it hear keywords and type their snippets. Expansion waits until both are on.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    /// Called when the window closes, by the user or by Done.
    var onClose: (() -> Void)?
    private let access: PermissionWatcher

    /// `isReturning` is for when the app ran before and has lost access, rather than a first launch.
    init(access: PermissionWatcher, isReturning: Bool) {
        self.access = access
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to xpnd"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let view = WelcomeView(access: access, isReturning: isReturning) { [weak window] in window?.close() }
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
        window.delegate = self
        followAccess()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.showFromMenuBar()
    }

    /// Floats over System Settings while access is off, so the icon can be dragged into its lists;
    /// comes forward once access is on, to say so.
    private func followAccess() {
        window?.level = access.isGranted ? .normal : .floating
        withObservationTracking { _ = access.isGranted } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.access.isGranted, self.window?.isVisible == true { self.show() }
                self.followAccess()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

extension NSWindow {
    /// Brings the window to the front from the menu bar. Since macOS 14, activating the app is only a
    /// request, which the system can turn down or grant late while the status menu is still closing;
    /// ordering it front regardless brings it up either way, and it becomes key once the app
    /// activates or it's clicked.
    func showFromMenuBar() {
        NSApp.activate()
        if !isVisible { center() }
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }
}

struct WelcomeView: View {
    let access: PermissionWatcher
    let isReturning: Bool
    let done: @MainActor () -> Void
    @State private var showsTroubleshooting = false

    var body: some View {
        Group {
            if access.isGranted { ready } else { setup }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Before access

    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(isReturning ? "xpnd needs access again" : "Welcome to xpnd")
                        .font(.title2.weight(.semibold))
                    Text("Type a keyword, and xpnd replaces it with your snippet.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if AppLocation.isTemporary { MoveToApplicationsNote() }
            Text(isReturning
                 ? "macOS turned off some of its access, so expansion is paused. Turn it back on to carry on."
                 : "xpnd needs two kinds of access: Input Monitoring to notice a keyword as you type it, and Accessibility to type the snippet in its place. It keeps only the last few characters, to match keywords, and never records or sends what you type.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, title: "Allow Input Monitoring", detail: "Turn on the switch next to xpnd.") {
                    PermissionControl(granted: access.inputMonitoring) { InputMonitoringPermission.openSettings() }
                }
                Step(number: 2, title: "Allow Accessibility", detail: "Turn on the switch next to xpnd.") {
                    PermissionControl(granted: access.accessibility) { AccessibilityPermission.openSettings() }
                }
                Step(number: 3, title: "Not in a list? Drag it in",
                     detail: "Or click + below the list and choose xpnd.") {
                    DragHandle()
                }
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                // Before access there's nothing to run, so closing quits; see `AppDelegate`.
                Text(isReturning ? "Waiting for access. This window moves on by itself."
                                 : "Waiting for access. This window moves on by itself; closing it quits xpnd.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Listed and switched on, but nothing happens?", isExpanded: $showsTroubleshooting) {
                Text("macOS can hold on to an older copy of xpnd, such as one that was rebuilt or updated since. In the list, select xpnd and click − to remove it, then drag it in again from here and turn it on. If keywords still don't expand, quit and reopen xpnd.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }

            HStack {
                Spacer()
                Button("Quit xpnd") { NSApp.terminate(nil) }
            }
        }
        .padding(28)
        .padding(.top, 8)
    }

    // MARK: - After access

    private var ready: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .green)
                }
            Text("xpnd is ready").font(.title2.weight(.semibold))
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("It runs in the menu bar:")
                    Image(systemName: "text.cursor")
                }
                Text("Type a snippet's keyword in any app, and xpnd puts the snippet in its place.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            if AppLocation.isTemporary { MoveToApplicationsNote() }
            Button("Done") { done() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 6)
        }
        .padding(32)
        .padding(.top, 8)
        .frame(maxWidth: .infinity)
    }
}

/// A button to the list in System Settings, or a check once access is on.
private struct PermissionControl: View {
    let granted: Bool
    let open: @MainActor () -> Void

    var body: some View {
        if granted {
            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Button("Open System Settings") { open() }
        }
    }
}

/// Shown while the app runs from its disk image: access and updates need it in Applications.
private struct MoveToApplicationsNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 8) {
                Text("Move xpnd to Applications first").fontWeight(.medium)
                Text("It's running from the disk image, where macOS won't keep its access and updates can't install. Quit, drag it to Applications, and open it from there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Applications") { NSWorkspace.shared.open(URL(filePath: "/Applications")) }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A numbered step with whatever control it needs on the right.
private struct Step<Control: View>: View {
    let number: Int
    let title: String
    var detail: String?
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control()
        }
    }
}

/// The app's icon, to drag into a list in System Settings.
private struct DragHandle: View {
    var body: some View {
        HStack(spacing: 6) {
            AppIconDragSource.Representable()
                .frame(width: 44, height: 44)
            Image(systemName: "arrow.right")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .foregroundStyle(.secondary.opacity(0.6))
        )
        .help("Drag into the list in System Settings")
    }
}

/// Drags the app itself, as Finder would, so System Settings adds it to the list it's dropped on.
final class AppIconDragSource: NSView, NSDraggingSource {
    private let bundleURL = Bundle.main.bundleURL
    private let icon = NSApp.applicationIconImage ?? NSImage()

    struct Representable: NSViewRepresentable {
        func makeNSView(context: Context) -> AppIconDragSource { AppIconDragSource() }
        func updateNSView(_ view: AppIconDragSource, context: Context) {}
    }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    /// System Settings is in front while this is dragged from.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
