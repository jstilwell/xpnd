import AppKit
import SwiftUI

/// The search panel the picker hotkey opens: type to filter, arrows to move, Return to insert, Esc to close.
@MainActor
final class PickerPanel: LauncherPanel {
    private let store: SnippetStore
    private let engine: ExpansionEngine

    init(store: SnippetStore, engine: ExpansionEngine) {
        self.store = store
        self.engine = engine
        super.init()
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    private func show() {
        // A fresh view each time, so the query and highlight start clean.
        present(PickerView(
            snippets: store.library.activeSnippets,
            choose: { [weak self] in self?.insert($0) },
            cancel: { [weak self] in self?.close() }
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
        let results = results // each read filters and sorts the whole library
        guard !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selected } ?? (delta > 0 ? -1 : results.count)
        selected = results[min(max(index + delta, 0), results.count - 1)].id
    }
}
