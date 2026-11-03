import SwiftUI

extension StoreError {
    var message: String {
        switch self {
        case .fileUnreadable: "Couldn't save snippets.yaml."
        case .duplicateKeyword(let keyword): "“\(keyword)” is already used by another snippet."
        case .encodingFailed: "Couldn't write the snippets as YAML, so nothing was saved."
        }
    }
}

/// Snippet saving for the main window's sidebar and Details pane. Every edit saves at once through
/// `store.update`. A reload from disk gives everything new ids, so a save finds its place by id,
/// then by name or keyword.
@MainActor @Observable
final class SnippetEditing {
    let store: SnippetStore
    var saveProblem: String?

    init(store: SnippetStore) {
        self.store = store
    }

    var readOnly: Bool { store.loadError != nil }

    func group(_ id: SnippetGroup.ID) -> SnippetGroup? { store.library.groups.first { $0.id == id } }
    func snippet(_ id: Snippet.ID) -> Snippet? { store.library.groups.lazy.flatMap(\.snippets).first { $0.id == id } }
    func group(containing id: Snippet.ID) -> SnippetGroup? {
        store.library.groups.first { $0.snippets.contains { $0.id == id } }
    }

    @discardableResult
    func save(_ change: (inout SnippetLibrary) -> Void) -> Bool {
        do {
            try store.update(change)
            saveProblem = nil
            return true
        } catch {
            saveProblem = error.message
            return false
        }
    }

    /// Saves `change` at the snippet's place, found by id, or by keyword if a reload gave it a new id.
    @discardableResult
    func save(at snippet: Snippet, _ change: (inout SnippetLibrary, _ group: Int, _ index: Int) -> Void) -> Bool {
        var found = false
        let saved = save { library in
            func place(_ match: (Snippet) -> Bool) -> (Int, Int)? {
                for (gi, group) in library.groups.enumerated() {
                    if let si = group.snippets.firstIndex(where: match) { return (gi, si) }
                }
                return nil
            }
            guard let (gi, si) = place({ $0.id == snippet.id }) ?? place({ $0.keyword == snippet.keyword }) else { return }
            found = true
            change(&library, gi, si)
        }
        if saved && !found { saveProblem = "That snippet changed in snippets.yaml. Select it again." }
        return saved && found
    }

    /// Saves `change` at the group's place, found by id, or by name if a reload gave it a new id.
    @discardableResult
    func save(at group: SnippetGroup, _ change: (inout SnippetLibrary, _ group: Int) -> Void) -> Bool {
        var found = false
        let saved = save { library in
            guard let gi = library.groups.firstIndex(where: { $0.id == group.id })
                ?? library.groups.firstIndex(where: { $0.name == group.name }) else { return }
            found = true
            change(&library, gi)
        }
        if saved && !found { saveProblem = "That group changed in snippets.yaml. Select it again." }
        return saved && found
    }

    func groupBinding<T>(_ group: SnippetGroup, _ key: WritableKeyPath<SnippetGroup, T>) -> Binding<T> {
        Binding(get: { self.group(group.id)?[keyPath: key] ?? group[keyPath: key] },
                set: { value in self.save(at: group) { $0.groups[$1][keyPath: key] = value } })
    }

    /// The new group's id, or nil if it wasn't saved.
    func addGroup() -> SnippetGroup.ID? {
        let names = Set(store.library.groups.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "New Group" : "New Group \($0)" }.first { !names.contains($0) }!
        let new = SnippetGroup(name: name, snippets: [])
        return save({ $0.groups.append(new) }) ? new.id : nil
    }

    func deleteGroup(_ group: SnippetGroup) -> Bool {
        save(at: group) { $0.groups.remove(at: $1) }
    }

    /// The new snippet's id, or nil if it wasn't saved.
    func addSnippet(to group: SnippetGroup) -> Snippet.ID? {
        let library = store.library
        let keyword = (1...).lazy.map { $0 == 1 ? ";new" : ";new\($0)" }.first { library.keywordProblem($0, for: nil) == nil }!
        let new = Snippet(name: "New Snippet", keyword: keyword, text: "")
        return save(at: group) { $0.groups[$1].snippets.append(new) } ? new.id : nil
    }

    func deleteSnippet(_ snippet: Snippet) -> Bool {
        save(at: snippet) { $0.groups[$1].snippets.remove(at: $2) }
    }
}

/// The Details editor for a snippet group: its fields, adding a snippet, and deleting the group.
struct SnippetGroupDetails: View {
    let editing: SnippetEditing
    let group: SnippetGroup
    @Binding var selection: SidebarItem?
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            TextField("Group", text: editing.groupBinding(group, \.name))
            TextField("Description", text: editing.groupBinding(group, \.description))
            Toggle("Enabled", isOn: editing.groupBinding(group, \.enabled))
            HStack {
                Button("Add Snippet", systemImage: "plus") {
                    if let id = editing.addSnippet(to: group) { selection = .snippet(id) }
                }
                Spacer()
                Button("Delete Group…", systemImage: "minus", role: .destructive) {
                    if group.snippets.isEmpty { deleteGroup() } else { confirmingDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(editing.readOnly)
        .confirmationDialog("Delete “\(group.name)” and its \(group.snippets.count) snippets?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: deleteGroup)
        }
    }

    private func deleteGroup() {
        if editing.deleteGroup(group) { selection = nil }
    }
}

/// The Details editor for one snippet, with its delete button.
struct SnippetDetails: View {
    let editing: SnippetEditing
    let snippet: Snippet
    let connections: ConnectionLibrary
    @Binding var selection: SidebarItem?

    var body: some View {
        VStack(spacing: 0) {
            SnippetEditorView(snippet: snippet, namespace: KeywordNamespace(snippets: editing.store.library, connections: connections),
                              readOnly: editing.readOnly) { change in
                editing.save(at: snippet) { change(&$0.groups[$1].snippets[$2]) }
            }
            HStack {
                Spacer()
                Button("Delete Snippet", systemImage: "minus", role: .destructive) {
                    let group = editing.group(containing: snippet.id)
                    if editing.deleteSnippet(snippet) { selection = group.map { .snippetGroup($0.id) } }
                }
                .disabled(editing.readOnly)
            }
            .padding(8)
        }
    }
}
