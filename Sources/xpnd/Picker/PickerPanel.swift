import AppKit
import SwiftUI

/// The search panel the picker hotkey opens: type to filter, arrows to move, Return to insert, Esc to close.
@MainActor
final class PickerPanel {
    /// How long to wait for the app that was in front to come back before inserting into it.
    private static let refocusTimeout: Duration = .seconds(1)

    private let store: SnippetStore
    private let engine: ExpansionEngine
    private let panel = KeyablePanel(
        contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
    )
    private var previous: NSRunningApplication?
    private var generation = 0

    init(store: SnippetStore, engine: ExpansionEngine) {
        self.store = store
        self.engine = engine
        panel.onResignKey = { [weak self] in self?.close() }
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func toggle() {
        if panel.isVisible { close() } else { show() }
    }

    private func show() {
        let front = NSWorkspace.shared.frontmostApplication
        previous = front == .current ? nil : front
        // A fresh view each time, so the query and highlight start clean.
        panel.contentView = NSHostingView(rootView: PickerView(
            snippets: store.library.activeSnippets,
            choose: { [weak self] in self?.insert($0) },
            cancel: { [weak self] in self?.close() }
        ))
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - visible.height / 3 - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel.orderOut(nil)
    }

    private func insert(_ snippet: Snippet) {
        close()
        let app = previous
        Task {
            if let app {
                NSApp.yieldActivation(to: app)
                app.activate()
                let deadline = ContinuousClock.now + Self.refocusTimeout
                while NSWorkspace.shared.frontmostApplication != app, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            await engine.expand(snippet, deletingCharacters: 0)
        }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onResignKey: (() -> Void)?

    // Clicking into another app doesn't deactivate xpnd (the panel is non-activating), so close here.
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

private struct PickerView: View {
    let snippets: [Snippet]
    let choose: (Snippet) -> Void
    let cancel: () -> Void
    @State private var query = ""
    @State private var selected: Snippet.ID?
    @FocusState private var focused: Bool

    private var results: [Snippet] { PickerFilter.filter(snippets, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search snippets", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(14)
                .focused($focused)
                .onSubmit { if let s = current { choose(s) } }
            Divider()
            ScrollViewReader { proxy in
                List(results, selection: $selected) { snippet in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(snippet.name).lineLimit(1)
                            Spacer()
                            Text(snippet.keyword).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(snippet.text.replacingOccurrences(of: "\n", with: " "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(snippet.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { choose(snippet) }
                }
                .listStyle(.plain)
                .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
            }
        }
        .frame(width: 560, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true; selected = results.first?.id }
        .onChange(of: query) { selected = results.first?.id }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { cancel(); return .handled }
    }

    private var current: Snippet? { results.first { $0.id == selected } ?? results.first }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : results.count)
        selected = results[min(max(index + delta, 0), results.count - 1)].id
    }
}
