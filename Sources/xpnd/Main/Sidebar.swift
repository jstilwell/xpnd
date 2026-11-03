import SwiftUI

enum SidebarItem: Hashable {
    case folder(ConnectionFolder.ID), connection(Connection.ID), snippetGroup(SnippetGroup.ID), snippet(Snippet.ID)
}

/// The main window's sidebar: the connection tree, then snippet groups as one-level folders.
/// Double-clicking a connection (or Connect in its menu) connects.
struct Sidebar: View {
    let connections: ConnectionStore
    let editing: SnippetEditing
    @Binding var selection: SidebarItem?
    let connect: (Connection.ID) -> Void

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
            if let id = Self.connection(in: items) { Button("Connect") { connect(id) } }
        } primaryAction: { items in
            if let id = Self.connection(in: items) { connect(id) }
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
