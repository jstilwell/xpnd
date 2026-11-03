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

/// Groups, their snippets, and the editor. Every edit saves at once through `store.update`.
struct SnippetsSettingsView: View {
    let store: SnippetStore
    @State private var groupID: SnippetGroup.ID?
    @State private var snippetID: Snippet.ID?
    /// A reload from disk gives everything new ids, so the selection is found again by these.
    @State private var groupName: String?
    @State private var snippetKeyword: String?
    @State private var search = ""
    @State private var saveProblem: String?
    @State private var confirmingDelete = false

    private var readOnly: Bool { store.loadError != nil }
    private var group: SnippetGroup? { store.library.groups.first { $0.id == groupID } }
    private var snippet: Snippet? { group?.snippets.first { $0.id == snippetID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError = store.loadError {
                Label("snippets.yaml has an error, so editing is off until it's fixed: \(loadError)",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).lineLimit(4).padding(8)
            }
            if let saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.circle").foregroundStyle(.red).padding(8)
            }
            NavigationSplitView {
                sidebar.navigationSplitViewColumnWidth(min: 160, ideal: 180)
            } content: {
                snippetList.navigationSplitViewColumnWidth(min: 220, ideal: 240)
            } detail: {
                if let snippet {
                    SnippetEditorView(snippet: snippet, library: store.library, readOnly: readOnly) { change in save(at: snippet) { change(&$0.groups[$1].snippets[$2]) } }
                } else {
                    ContentUnavailableView("No Snippet Selected", systemImage: "text.cursor")
                }
            }
            .toolbar(removing: .sidebarToggle)
            Text("Saved to ~/Library/Application Support/xpnd/snippets.yaml. Saving from xpnd rewrites the file and drops comments.")
                .font(.callout).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: 860, height: 560)
        .onChange(of: store.library) { reselect() }
        .onChange(of: groupID) {
            groupName = group?.name
            if snippet == nil { snippetID = nil } // another group was picked, not the same one found again
        }
        .onChange(of: snippetID) { snippetKeyword = snippet?.keyword }
        .onAppear { if groupID == nil { groupID = store.library.groups.first?.id } }
    }

    private var sidebar: some View {
        List(store.library.groups, selection: $groupID) { group in
            Text(group.name.isEmpty ? "Untitled" : group.name)
                .foregroundStyle(group.enabled ? .primary : .secondary)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Add Group", systemImage: "plus", action: addGroup)
                Button("Delete Group", systemImage: "minus") {
                    if group?.snippets.isEmpty == false { confirmingDelete = true } else { deleteGroup() }
                }
                .disabled(group == nil)
                Spacer()
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).padding(6).disabled(readOnly)
        }
        .confirmationDialog("Delete “\(group?.name ?? "")” and its \(group?.snippets.count ?? 0) snippets?",
                            isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: deleteGroup)
        }
    }

    @ViewBuilder private var snippetList: some View {
        if let group {
            VStack(spacing: 0) {
                Form {
                    TextField("Group", text: groupBinding(group, \.name))
                    TextField("Description", text: groupBinding(group, \.description))
                    Toggle("Enabled", isOn: groupBinding(group, \.enabled))
                }
                .disabled(readOnly).padding(8)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
                List(PickerFilter.filter(group.snippets, query: search), selection: $snippetID) { snippet in
                    VStack(alignment: .leading) {
                        Text(snippet.name.isEmpty ? "Untitled" : snippet.name)
                        Text(snippet.keyword).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .opacity(snippet.enabled ? 1 : 0.5)
                }
                HStack {
                    Button("Add Snippet", systemImage: "plus", action: addSnippet)
                    Button("Delete Snippet", systemImage: "minus", action: deleteSnippet).disabled(snippet == nil)
                    Spacer()
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).padding(6).disabled(readOnly)
            }
        } else {
            ContentUnavailableView("No Group Selected", systemImage: "folder")
        }
    }

    // MARK: Saving

    @discardableResult
    private func save(_ change: (inout SnippetLibrary) -> Void) -> Bool {
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
    private func save(at snippet: Snippet, _ change: (inout SnippetLibrary, _ group: Int, _ index: Int) -> Void) -> Bool {
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
    private func save(at group: SnippetGroup, _ change: (inout SnippetLibrary, _ group: Int) -> Void) -> Bool {
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

    private func groupBinding<T>(_ group: SnippetGroup, _ key: WritableKeyPath<SnippetGroup, T>) -> Binding<T> {
        Binding(get: { self.group?[keyPath: key] ?? group[keyPath: key] },
                set: { value in save(at: group) { $0.groups[$1][keyPath: key] = value } })
    }

    private func reselect() {
        let groups = store.library.groups
        if groupID != nil, group == nil { groupID = groups.first { $0.name == groupName }?.id }
        if snippetID != nil, snippet == nil { snippetID = group?.snippets.first { $0.keyword == snippetKeyword }?.id }
        // Follow in-app renames, so the next reload can still find them.
        groupName = group?.name
        snippetKeyword = snippet?.keyword
    }

    private func addGroup() {
        let names = Set(store.library.groups.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "New Group" : "New Group \($0)" }.first { !names.contains($0) }!
        let new = SnippetGroup(name: name, snippets: [])
        if save({ $0.groups.append(new) }) { groupID = new.id }
    }

    private func deleteGroup() {
        guard let group else { return }
        if save(at: group, { $0.groups.remove(at: $1) }) { groupID = nil }
    }

    private func addSnippet() {
        guard let group else { return }
        let library = store.library
        let keyword = (1...).lazy.map { $0 == 1 ? ";new" : ";new\($0)" }.first { library.keywordProblem($0, for: nil) == nil }!
        let new = Snippet(name: "New Snippet", keyword: keyword, text: "")
        if save(at: group, { $0.groups[$1].snippets.append(new) }) {
            search = ""
            snippetID = new.id
        }
    }

    private func deleteSnippet() {
        guard let snippet else { return }
        if save(at: snippet, { $0.groups[$1].snippets.remove(at: $2) }) { snippetID = nil }
    }
}
