import AppKit
import SwiftUI

/// The search panel the picker hotkey opens: type to filter, arrows to move, Return to insert, Esc to close.
@MainActor
final class PickerPanel: LauncherPanel {
    private let store: SnippetStore
    private let engine: ExpansionEngine
    private let openApp: () -> Void

    init(store: SnippetStore, engine: ExpansionEngine, openApp: @escaping () -> Void) {
        self.store = store
        self.engine = engine
        self.openApp = openApp
        super.init()
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    private func show() {
        // A fresh view each time, so the query and highlight start clean.
        present(PickerView(
            snippets: store.library.activeSnippets,
            groups: PickerFilter.groupNames(store.library),
            choose: { [weak self] in self?.insert($0) },
            cancel: { [weak self] in self?.close() },
            openApp: { [weak self] in
                self?.close()
                self?.openApp()
            }
        ))
    }

    private func insert(_ snippet: Snippet) {
        close()
        Task {
            await refocusPrevious()
            await engine.expand(snippet, deletingCharacters: 0)
        }
    }
}

private struct PickerView: View {
    let snippets: [Snippet]
    /// Each snippet's group name.
    let groups: [Snippet.ID: String]
    let choose: (Snippet) -> Void
    let cancel: () -> Void
    let openApp: () -> Void
    @State private var query = ""
    @State private var selected: Snippet.ID?
    @FocusState private var focused: Bool
    /// Filtered and sorted once per query: it searches every snippet's text.
    @State private var results: [Snippet] = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search snippets", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(14)
                .focused($focused)
                .onSubmit { if let s = current { choose(s) } }
            Divider()
            if snippets.isEmpty {
                VStack(spacing: 12) {
                    Text("No snippets yet").foregroundStyle(.secondary)
                    Text("Add them in the xpnd window.").font(.callout).foregroundStyle(.secondary)
                    Button("Open xpnd", action: openApp)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if results.isEmpty {
                Text("No snippets match").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(width: 560, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            focused = true
            results = PickerFilter.filter(snippets, query: query)
            selected = results.first?.id
        }
        .onChange(of: query) {
            results = PickerFilter.filter(snippets, query: query)
            selected = results.first?.id
        }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { cancel(); return .handled }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(results, selection: $selected) { snippet in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(snippet.name).lineLimit(1)
                        if let group = groups[snippet.id] {
                            Text(group).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
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

    private var current: Snippet? { results.first { $0.id == selected } ?? results.first }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : results.count)
        selected = results[min(max(index + delta, 0), results.count - 1)].id
    }
}
