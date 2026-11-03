import SwiftUI

enum SidebarItem: Hashable {
    case folder(ConnectionFolder.ID), connection(Connection.ID), snippetGroup(SnippetGroup.ID), snippet(Snippet.ID)
}

/// The main window's sidebar: the connection tree, then snippet groups as one-level folders.
/// Double-clicking a connection (or Connect in its menu) connects.
struct Sidebar: View {
    let connections: ConnectionEditing
    let editing: SnippetEditing
    @Binding var selection: SidebarItem?
    @Binding var focus: EditorFocus?
    /// A folder with something in it, waiting for Delete to be confirmed.
    @State private var confirmingDelete: ConnectionFolder?

    var body: some View {
        let library = editing.store.library
        let namespace = KeywordNamespace(snippets: library, connections: connections.library)
        List(selection: $selection) {
            Section("Connections") {
                OutlineGroup(connections.library.folders.map { ConnectionNode(folder: $0, namespace) }, children: \.children) { node in
                    row(node.title, detail: node.detail, symbol: node.symbol).tag(node.id)
                }
            }
            Section("Snippets") {
                ForEach(library.groups) { group in
                    DisclosureGroup {
                        ForEach(group.snippets) { snippet in
                            row(snippet.name.isEmpty ? "Untitled" : snippet.name, detail: snippet.keyword, symbol: "text.cursor")
                                .opacity(snippet.enabled ? 1 : 0.5)
                                .tag(SidebarItem.snippet(snippet.id))
                        }
                    } label: {
                        HStack {
                            row(group.name.isEmpty ? "Untitled" : group.name, detail: nil, symbol: "folder")
                                .foregroundStyle(group.enabled ? .primary : .secondary)
                            Spacer()
                            Toggle("Enabled", isOn: editing.groupBinding(group, \.enabled))
                                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                                .disabled(editing.readOnly)
                        }
                        .help(group.description)
                        .tag(SidebarItem.snippetGroup(group.id))
                    }
                }
            }
        }
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            menu(for: items)
        } primaryAction: { items in
            if let id = Self.connection(in: items) { connections.connect(id) }
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
                Button("Add Snippet Group", systemImage: "plus") {
                    if let id = editing.addGroup() { selection = .snippetGroup(id) }
                }
                .disabled(editing.readOnly)
                Spacer()
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).padding(6)
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
            Button("Connect") { connections.connect(id) }
            Group {
                Button("Duplicate") { select(connections.duplicate(id).map(SidebarItem.connection), focus: .name, else: .connection(id)) }
                moveMenu(.connection(id))
                Divider()
                Button("Delete", role: .destructive) { delete(.connection(id)) }
            }
            .disabled(readOnly)
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

    private static func connection(in items: Set<SidebarItem>) -> Connection.ID? {
        guard items.count == 1, case .connection(let id)? = items.first else { return nil }
        return id
    }

    private func row(_ title: String, detail: String?, symbol: String) -> some View {
        HStack {
            Label(title, systemImage: symbol).lineLimit(1)
            if let detail {
                Text(detail).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// A folder or connection in the sidebar's tree. A folder shows its effective activation string.
private struct ConnectionNode: Identifiable {
    let id: SidebarItem
    let title: String
    let detail: String?
    let symbol: String
    /// nil for a connection or an empty folder, so neither gets a disclosure arrow.
    let children: [ConnectionNode]?

    init(folder: ConnectionFolder, _ namespace: KeywordNamespace) {
        id = .folder(folder.id)
        title = folder.name
        detail = namespace.effectiveActivation(ofFolder: folder.id).string
        symbol = "folder"
        let kids = folder.connections.map(ConnectionNode.init(connection:)) + folder.folders.map { ConnectionNode(folder: $0, namespace) }
        children = kids.isEmpty ? nil : kids
    }

    init(connection: Connection) {
        id = .connection(connection.id)
        title = connection.name
        detail = connection.activation.flatMap { $0.isEmpty ? nil : $0 }
        symbol = connection.type == .ssh ? "terminal" : "display"
        children = nil
    }
}
