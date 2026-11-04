import SwiftUI

enum SidebarItem: Hashable {
    case folder(ConnectionFolder.ID), connection(Connection.ID), snippetGroup(SnippetGroup.ID), snippet(Snippet.ID)

    /// Plain text carried by a sidebar drag, so no custom type needs declaring; anything else dropped
    /// on the sidebar isn't one of these and is ignored.
    var dragText: String {
        switch self {
        case .folder(let id): "xpnd-sidebar:folder:\(id.uuidString)"
        case .connection(let id): "xpnd-sidebar:connection:\(id.uuidString)"
        case .snippetGroup(let id): "xpnd-sidebar:group:\(id.uuidString)"
        case .snippet(let id): "xpnd-sidebar:snippet:\(id.uuidString)"
        }
    }

    init?(dragText: String) {
        let parts = dragText.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "xpnd-sidebar", let id = UUID(uuidString: parts[2]) else { return nil }
        switch parts[1] {
        case "folder": self = .folder(id)
        case "connection": self = .connection(id)
        case "group": self = .snippetGroup(id)
        case "snippet": self = .snippet(id)
        default: return nil
        }
    }
}

/// The main window's sidebar: the connection tree, then snippet groups as one-level folders.
/// Double-clicking a connection (or Connect in its menu) connects; double-clicking a folder or group opens or closes it. Searching filters both: the
/// connections as a flat list, as the launcher shows them, and each group's snippets as the picker does.
/// Rows drag (`draggable`, carrying `SidebarItem.dragText`): between rows to reorder or move into
/// that list (`dropDestination` on the `ForEach`, which reports the index before the item is taken
/// out), onto a folder or group to move into it. Drops do nothing while searching, because the rows
/// shown aren't the stored order.
struct Sidebar: View {
    let connections: ConnectionEditing
    let editing: SnippetEditing
    @Binding var selection: SidebarItem?
    @Binding var focus: EditorFocus?
    let openSettings: () -> Void
    /// A folder with something in it, waiting for Delete to be confirmed.
    @State private var confirmingDelete: ConnectionFolder?
    @State private var search = ""
    /// Groups opened by hand; every group shows open while searching.
    @State private var expandedGroups: Set<SnippetGroup.ID> = []
    @State private var expandedFolders: Set<ConnectionFolder.ID> = []
    /// The group a drag is over (its "into" target), so it highlights.
    @State private var targetedGroup: SnippetGroup.ID?

    private var searching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        List(selection: $selection) {
            connectionsSection
            snippetsSection
        }
        .searchable(text: $search, placement: .sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            menu(for: items)
        } primaryAction: { items in
            switch items.count == 1 ? items.first : nil {
            case .connection(let id)?: connections.connect(id, NSEvent.modifierFlags.contains(.command))
            case .snippetGroup(let id)?: expandedGroups.formSymmetricDifference([id])
            case .folder(let id)?: expandedFolders.formSymmetricDifference([id])
            default: break
            }
        }
        .confirmationDialog(
            "Delete “\(confirmingDelete?.name ?? "")” and everything in it?",
            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
            presenting: confirmingDelete
        ) { folder in
            Button("Delete", role: .destructive) { delete(.folder(folder.id)) }
        } message: { folder in
            Text("\(EditorRules.count(folder.allConnections.count, "connection")) and \(EditorRules.count(folder.allFolders.count - 1, "folder"))")
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Version \(Self.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Settings", systemImage: "gearshape", action: openSettings)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .padding(6)
        }
    }

    private var connectionsSection: some View {
        let namespace = KeywordNamespace(snippets: editing.store.library, connections: connections.library)
        return Section {
                if searching {
                    ForEach(ConnectionFilter.filter(ConnectionFilter.entries(connections.library), query: search), id: \.connection.id) { entry in
                        sidebarRow(entry.connection.name, detail: entry.pathText, symbol: ConnectionNode(connection: entry.connection, inherited: nil).symbol,
                                   color: entry.color)
                            .tag(SidebarItem.connection(entry.connection.id))
                    }
                } else {
                    ForEach(connections.library.folders) { folder in
                        FolderRows(folder: folder, namespace: namespace, drops: drops, inherited: nil, expanded: $expandedFolders)
                    }
                    .dropDestination(for: String.self) { texts, index in
                        for item in sidebarItems(texts) { drops.insert(item, nil, index, .folders) }
                    }
                }
            } header: {
                heading("Connections") { addConnectionsMenu }
            }
            .collapsible(false)
    }

    private var snippetsSection: some View {
        let library = editing.store.library
        return Section {
                ForEach(library.groups) { group in
                    let shown = searching ? PickerFilter.filter(group.snippets, query: search) : group.snippets
                    if !searching || !shown.isEmpty {
                        snippetGroup(group, shown, expanded: Binding(
                            get: { searching || expandedGroups.contains(group.id) },
                            set: { if $0 { expandedGroups.insert(group.id) } else { expandedGroups.remove(group.id) } }))
                    }
                }
                .dropDestination(for: String.self) { texts, index in
                    for item in sidebarItems(texts) {
                        switch item {
                        case .snippetGroup(let id):
                            var probe = editing.store.library
                            guard !searching, probe.moveGroup(id, to: index), probe != editing.store.library else { continue }
                            _ = editing.moveGroup(id, to: index)
                        // A snippet dropped under a group's row goes into that group.
                        case .snippet(let id):
                            if let group = EditorRules.aboveTheLine(index: index, siblings: library.groups.map(\.id), container: nil) {
                                dropSnippet(id, into: group, at: nil)
                            }
                        default: break
                        }
                    }
                }
            } header: {
                heading("Snippets") {
                    Button("Add Snippet Group", systemImage: "plus") {
                        if let id = editing.addGroup() { selection = .snippetGroup(id) }
                    }
                    .disabled(editing.readOnly)
                }
            }
            .collapsible(false)
    }

    private static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    /// A section heading with its "+" at the right; the sections never collapse, so no hover chevron shifts it.
    private func heading<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
            Spacer()
            control().labelStyle(.iconOnly).buttonStyle(.borderless)
        }
    }

    /// Adds into the selected folder (or a selected connection's); a top-level folder is always offered.
    private var addConnectionsMenu: some View {
        let library = connections.library
        let target = EditorRules.addTarget(for: selection, in: library)
        return Menu("Add", systemImage: "plus") {
            if let target, let name = library.folder(target)?.name {
                Button("New Connection in “\(name)”") { select(connections.addConnection(in: target).map(SidebarItem.connection), focus: .name, else: .folder(target)) }
                Button("New Folder in “\(name)”") { select(connections.addFolder(in: target).map(SidebarItem.folder), focus: .name, else: .folder(target)) }
                Divider()
            }
            Button("New Top-Level Folder") { select(connections.addFolder(in: nil).map(SidebarItem.folder), focus: .name) }
        }
        .menuIndicator(.hidden).fixedSize()
        .disabled(connections.readOnly)
    }

    /// What drops do; `FolderRows` gets the same so nested levels behave like the top one.
    private var drops: SidebarDrops {
        SidebarDrops(
            insert: { item, container, index, among in
                switch (item, among) {
                case (.connection, .connections), (.folder, .folders): drop(item, to: container, at: index)
                // A connection dropped under a folder's row goes into that folder.
                case (.connection, .folders):
                    let siblings = (container.flatMap(connections.library.folder) ?? nil)?.folders.map(\.id) ?? connections.library.folders.map(\.id)
                    if let target = EditorRules.aboveTheLine(index: index, siblings: siblings, container: container) { drop(item, to: target, at: nil) }
                // A folder dropped among a folder's connections goes into that folder.
                case (.folder, .connections): if let container { drop(item, to: container, at: nil) }
                default: break
                }
            },
            into: { item, folder in drop(item, to: folder, at: nil) })
    }

    /// Saves a move only if the model accepts it and it changes something: a refused drop (a folder
    /// into its own subtree, an item back onto its own folder) and a drop back where it started do
    /// nothing, instead of a red "changed" message or a rewrite that loses the file's comments.
    private func drop(_ item: SidebarItem, to container: ConnectionFolder.ID?, at index: Int?) {
        var probe = connections.library
        guard !searching, probe.move(item, to: container, at: index), probe != connections.library else { return }
        _ = connections.move(item, to: container, at: index)
    }

    private func dropSnippet(_ id: Snippet.ID, into group: SnippetGroup.ID, at index: Int?) {
        var probe = editing.store.library
        guard !searching, probe.moveSnippet(id, to: group, at: index), probe != editing.store.library else { return }
        _ = editing.moveSnippet(id, to: group, at: index)
    }

    private func snippetGroup(_ group: SnippetGroup, _ snippets: [Snippet], expanded: Binding<Bool>) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            ForEach(snippets) { snippet in
                sidebarRow(snippet.name.isEmpty ? "Untitled" : snippet.name, detail: snippet.keyword, symbol: "text.cursor")
                    .opacity(snippet.enabled ? 1 : 0.5)
                    .tag(SidebarItem.snippet(snippet.id))
                    .draggable(SidebarItem.snippet(snippet.id).dragText)
            }
            .dropDestination(for: String.self) { texts, index in
                for case .snippet(let id) in sidebarItems(texts) { dropSnippet(id, into: group.id, at: index) }
            }
        } label: {
            HStack {
                sidebarRow(group.name.isEmpty ? "Untitled" : group.name, detail: nil, symbol: "folder")
                    .foregroundStyle(group.enabled ? .primary : .secondary)
                Spacer()
                Button("New Snippet", systemImage: "plus") { addSnippet(to: group) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(editing.readOnly)
                Toggle("Enabled", isOn: editing.groupBinding(group, \.enabled))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    .disabled(editing.readOnly)
            }
            .help(group.description)
            .tag(SidebarItem.snippetGroup(group.id))
            .draggable(SidebarItem.snippetGroup(group.id).dragText)
            .dropDestination(for: String.self) { texts, _ in
                for case .snippet(let id) in sidebarItems(texts) { dropSnippet(id, into: group.id, at: nil) }
                return true
            } isTargeted: { targetedGroup = $0 ? group.id : nil }
            .background(targetedGroup == group.id ? Color.accentColor.opacity(0.2) : .clear)
        }
    }

    @ViewBuilder private func menu(for items: Set<SidebarItem>) -> some View {
        let readOnly = connections.readOnly
        switch items.count == 1 ? items.first : nil {
        case .folder(let id)?:
            Group {
                Button("New Connection") { select(connections.addConnection(in: id).map(SidebarItem.connection), focus: .name, else: .folder(id)) }
                Button("New Folder") { select(connections.addFolder(in: id).map(SidebarItem.folder), focus: .name, else: .folder(id)) }
                Button("Rename") { select(.folder(id), focus: .name) }
                Button("Set Activation…") { select(.folder(id), focus: .activation) }
                moveMenu(.folder(id))
                Divider()
                Button("Delete", role: .destructive) {
                    guard let folder = connections.library.folder(id) else { return }
                    if folder.connections.isEmpty && folder.folders.isEmpty { delete(.folder(id)) } else { confirmingDelete = folder }
                }
            }
            .disabled(readOnly)
        case .connection(let id)?:
            Button("Connect") { connections.connect(id, false) }
            Group {
                Button("Duplicate") { select(connections.duplicate(id).map(SidebarItem.connection), focus: .name, else: .connection(id)) }
                moveMenu(.connection(id))
                Divider()
                Button("Delete", role: .destructive) { delete(.connection(id)) }
            }
            .disabled(readOnly)
        case .snippetGroup(let id)?:
            Button("New Snippet") {
                if let group = editing.store.library.groups.first(where: { $0.id == id }) { addSnippet(to: group) }
            }
            .disabled(editing.readOnly)
        default:
            if items.isEmpty {
                Button("New Folder") { select(connections.addFolder(in: nil).map(SidebarItem.folder), focus: .name) }
                    .disabled(readOnly)
            }
        }
    }

    private func moveMenu(_ item: SidebarItem) -> some View {
        let library = connections.library
        return Menu("Move to…") {
            if case .folder(let id) = item, library.folderPath(of: id).count > 1 {
                Button("Top Level") { move(item, to: nil) }
                Divider()
            }
            ForEach(library.moveTargets(for: item)) { folder in
                Button(library.folderPath(of: folder.id).map(\.name).joined(separator: " / ")) {
                    move(item, to: folder.id)
                }
            }
        }
    }

    /// nil is an add that failed: `fallback`'s Details then shows why.
    private func select(_ item: SidebarItem?, focus field: EditorFocus, else fallback: SidebarItem? = nil) {
        guard let item else {
            if let fallback { selection = fallback }
            return
        }
        selection = item
        focus = field
    }

    /// Opens the group so the new snippet shows, then selects it; on failure the group's Details shows why.
    private func addSnippet(to group: SnippetGroup) {
        guard let id = editing.addSnippet(to: group, connections: connections.library) else { selection = .snippetGroup(group.id); return }
        expandedGroups.insert(group.id)
        selection = .snippet(id)
    }

    /// On failure the item is selected, so its Details shows why.
    private func move(_ item: SidebarItem, to destination: ConnectionFolder.ID?) {
        if !connections.move(item, to: destination) { selection = item }
    }

    private func delete(_ item: SidebarItem) {
        if connections.delete(item) {
            if selection == item { selection = nil }
        } else {
            selection = item
        }
    }

}

/// The sidebar items a drag carries; any other text is ignored.
private func sidebarItems(_ texts: [String]) -> [SidebarItem] {
    texts.compactMap(SidebarItem.init(dragText:))
}

private func sidebarRow(_ title: String, detail: String?, symbol: String, color: ItemColor? = nil) -> some View {
    HStack {
        Label(title, systemImage: symbol).lineLimit(1).foregroundStyle(color?.ui ?? Color.primary)
        if let detail {
            Text(detail).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// What the sidebar does with a drop, shared by every level of the tree.
private struct SidebarDrops {
    enum List { case connections, folders }
    /// Between rows of `container`'s list `among` (nil container: the top-level folders).
    let insert: (SidebarItem, ConnectionFolder.ID?, Int, List) -> Void
    /// Onto a folder's row.
    let into: (SidebarItem, ConnectionFolder.ID) -> Void
}

/// One folder and everything in it: its connections, then its subfolders, each a `FolderRows`.
/// Each list takes drops between its rows; the folder's own row takes drops into it.
private struct FolderRows: View {
    let folder: ConnectionFolder
    let namespace: KeywordNamespace
    let drops: SidebarDrops
    /// The nearest ancestor's colour, for anything in here without its own.
    let inherited: ItemColor?
    /// Every open folder in the tree, shared by all levels so the sidebar can toggle one on double-click.
    @Binding var expanded: Set<ConnectionFolder.ID>
    @State private var targeted = false
    private var color: ItemColor? { folder.color ?? inherited }

    var body: some View {
        // An empty folder is a plain row: a DisclosureGroup would give it a pointless arrow.
        if folder.connections.isEmpty && folder.folders.isEmpty {
            label
        } else {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(folder.id) },
                set: { if $0 { expanded.insert(folder.id) } else { expanded.remove(folder.id) } })
            ) {
                ForEach(folder.connections) { connection in
                    let node = ConnectionNode(connection: connection, inherited: color)
                    sidebarRow(node.title, detail: node.detail, symbol: node.symbol, color: node.color)
                        .tag(node.id)
                        .draggable(node.id.dragText)
                }
                .dropDestination(for: String.self) { texts, index in
                    for item in sidebarItems(texts) { drops.insert(item, folder.id, index, .connections) }
                }
                ForEach(folder.folders) { child in
                    FolderRows(folder: child, namespace: namespace, drops: drops, inherited: color, expanded: $expanded)
                }
                .dropDestination(for: String.self) { texts, index in
                    for item in sidebarItems(texts) { drops.insert(item, folder.id, index, .folders) }
                }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        let node = ConnectionNode(folder: folder, namespace)
        return sidebarRow(node.title, detail: node.detail, symbol: node.symbol, color: color)
            .tag(node.id)
            .draggable(node.id.dragText)
            .dropDestination(for: String.self) { texts, _ in
                for item in sidebarItems(texts) { drops.into(item, folder.id) }
                return true
            } isTargeted: { targeted = $0 }
            .background(targeted ? Color.accentColor.opacity(0.2) : .clear)
    }
}

/// How a folder or connection shows in the sidebar. A folder shows its effective activation string.
private struct ConnectionNode {
    let id: SidebarItem
    let title: String
    let detail: String?
    let symbol: String
    let color: ItemColor?

    init(folder: ConnectionFolder, _ namespace: KeywordNamespace) {
        id = .folder(folder.id)
        title = folder.name
        detail = namespace.effectiveActivation(ofFolder: folder.id).string
        symbol = "folder"
        color = folder.color
    }

    init(connection: Connection, inherited: ItemColor?) {
        id = .connection(connection.id)
        title = connection.name
        detail = connection.activation.flatMap { $0.isEmpty ? nil : $0 }
        symbol = connection.type.symbol
        color = connection.color ?? inherited
    }
}
