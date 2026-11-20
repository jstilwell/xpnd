import SwiftUI

extension StoreError {
    /// Why a save to snippets.yaml failed.
    var message: String { message(file: "snippets", owner: "snippet") }

    /// `file` without ".yaml"; `owner` is what else could hold a duplicate string.
    func message(file: String, owner: String) -> String {
        switch self {
        case .fileUnreadable: "Couldn't save \(file).yaml."
        case .duplicateKeyword(let keyword): "“\(keyword)” is already used by another \(owner)."
        case .encodingFailed: "Couldn't write the \(file) as YAML, so nothing was saved."
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
        let new = SnippetGroup(name: EditorRules.uniqueName("New Group", taken: Set(store.library.groups.map(\.name))), snippets: [])
        return save({ $0.groups.append(new) }) ? new.id : nil
    }

    /// `undo`: the acting window's; ⌘Z then puts the group back at its place.
    func deleteGroup(_ group: SnippetGroup, undo: UndoManager? = nil) -> Bool {
        var removed: (group: SnippetGroup, index: Int)?
        guard save(at: group, { removed = ($0.groups.remove(at: $1), $1) }), let removed else { return false }
        register(undo, "Delete “\(EditorRules.displayName(group.name))”") { $0.restoreGroup(removed.group, at: removed.index) }
        return true
    }

    /// Registers `change` as the undo of what was just saved.
    private func register(_ undo: UndoManager?, _ name: String, _ change: @escaping @Sendable (inout SnippetLibrary) -> Void) {
        guard let undo else { return }
        undo.registerUndo(withTarget: self) { editing in
            MainActor.assumeIsolated { _ = editing.save(change) }
        }
        undo.setActionName(name)
    }

    /// The new snippet's id, or nil if it wasn't saved. Its keyword is free in both files.
    func addSnippet(to group: SnippetGroup, connections: ConnectionLibrary) -> Snippet.ID? {
        let namespace = KeywordNamespace(snippets: store.library, connections: connections)
        let keyword = (1...).lazy.map { $0 == 1 ? ";new" : ";new\($0)" }.first { namespace.problem($0, for: nil) == nil }!
        let new = Snippet(name: "New Snippet", keyword: keyword, text: "")
        return save(at: group) { $0.groups[$1].snippets.append(new) } ? new.id : nil
    }

    /// A copy just after the original: the next free name, and the first free keyword of `keyword2`, `keyword3`….
    func duplicateSnippet(_ snippet: Snippet, connections: ConnectionLibrary) -> Snippet.ID? {
        let namespace = KeywordNamespace(snippets: store.library, connections: connections)
        var copy = snippet
        copy.id = UUID()
        copy.keyword = (2...).lazy.map { "\(snippet.keyword)\($0)" }.first { namespace.problem($0, for: nil) == nil }!
        copy.name = EditorRules.uniqueName(snippet.name, taken: Set(store.library.groups.flatMap(\.snippets).map(\.name)))
        return save(at: snippet) { $0.groups[$1].snippets.insert(copy, at: $2 + 1) } ? copy.id : nil
    }

    func moveSnippet(_ id: Snippet.ID, to group: SnippetGroup.ID, at index: Int?, undo: UndoManager? = nil) -> Bool {
        guard let moved = snippet(id), let place = store.library.placement(ofSnippet: id),
              save({ $0.moveSnippet(id, to: group, at: index) }) else { return false }
        register(undo, "Move “\(EditorRules.displayName(moved.name))”") { library in
            if let current = library.snippetID(id: id, keyword: moved.keyword) { library.moveSnippetBack(current, to: place) }
        }
        return true
    }

    /// `index` counts before the move, as a drop reports it.
    func moveGroup(_ id: SnippetGroup.ID, to index: Int, undo: UndoManager? = nil) -> Bool {
        guard let moved = group(id), let from = store.library.groups.firstIndex(where: { $0.id == id }),
              save({ $0.moveGroup(id, to: index) }) else { return false }
        register(undo, "Move “\(EditorRules.displayName(moved.name))”") { library in
            guard let now = library.groups.firstIndex(where: { $0.id == id }) ?? library.groups.firstIndex(where: { $0.name == moved.name })
            else { return }
            let group = library.groups.remove(at: now)
            library.groups.insert(group, at: min(from, library.groups.count))
        }
        return true
    }

    /// `undo`: the acting window's; ⌘Z then puts the snippet back in its group (found by name after a reload).
    func deleteSnippet(_ snippet: Snippet, undo: UndoManager? = nil) -> Bool {
        var removed: (snippet: Snippet, place: SnippetPlacement)?
        guard save(at: snippet, { library, gi, si in
            let place = SnippetPlacement(groupID: library.groups[gi].id, groupName: library.groups[gi].name, index: si)
            removed = (library.groups[gi].snippets.remove(at: si), place)
        }), let removed else { return false }
        register(undo, "Delete “\(EditorRules.displayName(snippet.name))”") { $0.restoreSnippet(removed.snippet, at: removed.place) }
        return true
    }
}

/// The Details editor for a snippet group: its fields, adding a snippet, and deleting the group.
struct SnippetGroupDetails: View {
    let editing: SnippetEditing
    let group: SnippetGroup
    let connections: ConnectionLibrary
    @Binding var selection: SidebarItem?
    /// The sidebar's Rename asks for `.name`; consumed here.
    @Binding var focus: EditorFocus?
    /// Asks (when the group holds snippets), then deletes it.
    let delete: () -> Void
    @FocusState private var nameFocused: Bool

    var body: some View {
        Form {
            CommittingTextField("Group", text: group.name) { editing.groupBinding(group, \.name).wrappedValue = $0 }.id(group.id)
                .focused($nameFocused)
            CommittingTextField("Description", text: group.description) { editing.groupBinding(group, \.description).wrappedValue = $0 }
                .id(group.id)
            Toggle("Enabled", isOn: editing.groupBinding(group, \.enabled))
            HStack {
                Button("Add Snippet", systemImage: "plus") {
                    if let id = editing.addSnippet(to: group, connections: connections) { selection = .snippet(id) }
                }
                Spacer()
                Button("Delete Group…", systemImage: "minus", role: .destructive, action: delete)
            }
        }
        .formStyle(.grouped)
        .disabled(editing.readOnly)
        .onChange(of: focus, initial: true) {
            guard focus == .name else { return }
            focus = nil
            Task { nameFocused = true } // the next turn, once this view is in the window
        }
    }
}

/// The Details editor for one snippet, with its delete button.
struct SnippetDetails: View {
    let editing: SnippetEditing
    let snippet: Snippet
    let connections: ConnectionLibrary
    /// Asks, then deletes this snippet.
    let delete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SnippetEditorView(snippet: snippet, namespace: KeywordNamespace(snippets: editing.store.library, connections: connections),
                              readOnly: editing.readOnly) { change in
                editing.save(at: snippet) { change(&$0.groups[$1].snippets[$2]) }
            }
            HStack {
                Spacer()
                Button("Delete Snippet", systemImage: "minus", role: .destructive, action: delete)
                    .disabled(editing.readOnly)
            }
            .padding(8)
        }
    }
}
