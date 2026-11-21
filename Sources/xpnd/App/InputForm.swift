import AppKit
import SwiftUI

/// The one form that asks for a snippet's `#{input:}` values, floating near the window being typed in.
@MainActor enum InputForm {
    /// How long to wait for the app typed in to come back in front before pasting into it.
    static let refocusTimeout: Duration = .seconds(1)

    private static var current: InputFormPanel?

    /// The value given for each field's label, or nil when cancelled. Either way, it tries to bring back the app
    /// that was in front; if that fails, `ExpansionEngine` sees another app in front and pastes nothing.
    static func ask(_ fields: [InputField]) async -> [String: String]? {
        guard current == nil else { return nil }
        let previous = NSWorkspace.shared.frontmostApplication
        let values = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let panel = InputFormPanel(fields: fields, near: previous.flatMap { frontWindowFrame(of: $0) }) { values in
                    current = nil
                    continuation.resume(returning: values)
                }
                current = panel
                panel.show()
            }
        } onCancel: {
            // Another app came forward, which ends the expansion: left open, the form would take an answer only
            // to throw it away, and no other keyword would expand until someone closed it.
            Task { @MainActor in current?.cancel() }
        }
        // Cancelled that way, the user chose the app now in front.
        if !Task.isCancelled, let previous, previous != .current { await refocus(previous) }
        return values
    }

    private static func refocus(_ app: NSRunningApplication) async {
        NSApp.yieldActivation(to: app)
        app.activate()
        let deadline = ContinuousClock.now + refocusTimeout
        while NSWorkspace.shared.frontmostApplication != app, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The app's frontmost on-screen window, in AppKit's bottom-left-origin screen coordinates.
    private static func frontWindowFrame(of app: NSRunningApplication) -> NSRect? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString: Any]]
        guard let info = windows?.first(where: {
            ($0[kCGWindowOwnerPID] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer] as? Int) == 0
        }), let bounds = info[kCGWindowBounds] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: bounds),
              let primary = NSScreen.screens.first else { return nil }
        return NSRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}

@MainActor private final class InputFormPanel: NSObject, NSWindowDelegate {
    // Non-activating, as Spotlight is: it takes the keyboard without xpnd asking to become the active app,
    // which macOS 14 may refuse an app in the background.
    private let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: true)
    private let anchor: NSRect?
    private var finish: (([String: String]?) -> Void)?

    init(fields: [InputField], near anchor: NSRect?, finish: @escaping ([String: String]?) -> Void) {
        self.anchor = anchor
        self.finish = finish
        super.init()
        panel.title = "xpnd"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Shows over full-screen apps too, as the picker does.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: InputFormView(
            fields: fields, submit: { [weak self] in self?.end($0) }, cancel: { [weak self] in self?.end(nil) }
        ))
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        panel.delegate = self
    }

    func show() {
        panel.layoutIfNeeded()
        if let anchor {
            // Centred across the window, a third of the way down it.
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY - anchor.height / 3 - size.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func cancel() { end(nil) }

    private func end(_ values: [String: String]?) {
        guard let finish else { return }
        self.finish = nil
        panel.close()
        finish(values)
    }

    func windowWillClose(_ notification: Notification) {
        end(nil)
    }
}

private struct InputFormView: View {
    let fields: [InputField]
    let submit: ([String: String]) -> Void
    let cancel: () -> Void
    @State private var values: [String]
    @FocusState private var focused: Int?

    init(fields: [InputField], submit: @escaping ([String: String]) -> Void, cancel: @escaping () -> Void) {
        self.fields = fields
        self.submit = submit
        self.cancel = cancel
        _values = State(initialValue: fields.map {
            switch $0.kind {
            case .text(let def): def
            case .choice(let options): options.first ?? ""
            case .multiline: ""
            }
        })
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            Form {
                ForEach(fields.indices, id: \.self) { i in
                    field(i)
                }
            }
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                // ⌘Return too, since Return makes a new line in a long input.
                Button("Insert", action: done).keyboardShortcut(.defaultAction)
                    .background(Button("", action: done).keyboardShortcut(.return, modifiers: .command).opacity(0))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = 0 }
    }

    @ViewBuilder private func field(_ i: Int) -> some View {
        let label = fields[i].label
        switch fields[i].kind {
        case .text:
            TextField(text: $values[i]) { Text(label) }
                .focused($focused, equals: i)
                .onSubmit(done)
        case .choice(let options):
            Picker(label, selection: $values[i]) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .focused($focused, equals: i)
        case .multiline:
            LabeledContent(label) {
                TextEditor(text: $values[i])
                    .font(.body)
                    .frame(height: 72)
                    .focused($focused, equals: i)
            }
        }
    }

    private func done() {
        submit(Dictionary(fields.indices.map { (fields[$0].label, values[$0]) }, uniquingKeysWith: { first, _ in first }))
    }
}
