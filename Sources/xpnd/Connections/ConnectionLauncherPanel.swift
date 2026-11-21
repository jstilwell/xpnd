import AppKit
import SwiftUI

/// The search panel the connection hotkey opens: type to filter (or, with the query empty, pick from Favorites
/// and Recent or browse the folder tree), Return to connect, Esc to close.
@MainActor
final class ConnectionLauncherPanel: LauncherPanel {
    /// `recents`: connection ids, newest first.
    func toggle(
        library: ConnectionLibrary,
        recents: [Connection.ID],
        onOpenApp: @escaping () -> Void,
        connect: @escaping (Connection.ID, pid_t?, _ sudo: Bool) async -> Void
    ) {
        if isVisible { close(); return }
        // A fresh view each time, so the query and highlight start clean.
        present(ConnectionLauncherView(
            library: library,
            recents: recents,
            choose: { [weak self] id, sudo in
                guard let self else { return }
                close()
                // Guarded against the app that was in front when the panel opened, not whatever is in front after refocusing.
                let target = previousApp?.processIdentifier
                Task {
                    await self.refocusPrevious()
                    await connect(id, target, sudo)
                }
            },
            cancel: { [weak self] in self?.close() },
            openApp: { [weak self] in self?.close(); onOpenApp() }
        ))
    }
}

/// A row of the launcher's list. A connection can be in Favorites or Recent and in the tree, so each is its own row.
private enum LauncherRow: Hashable {
    case favorite(Connection.ID), recent(Connection.ID), tree(UUID)
}

private struct ConnectionLauncherView: View {
    let library: ConnectionLibrary
    let recents: [Connection.ID]
    let choose: (Connection.ID, _ sudo: Bool) -> Void
    let cancel: () -> Void
    let openApp: () -> Void
    /// ⌘ on Return, keypad Enter or a double-click connects with sudo.
    private var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
    /// Return with ⌘ may reach both the field's submit and the key handler; the first one wins.
    @State private var activated = false
    @State private var query = ""
    @State private var selected: LauncherRow?
    @State private var expanded: Set<ConnectionFolder.ID>
    @FocusState private var focused: Bool

    init(
        library: ConnectionLibrary, recents: [Connection.ID], choose: @escaping (Connection.ID, _ sudo: Bool) -> Void,
        cancel: @escaping () -> Void, openApp: @escaping () -> Void
    ) {
        self.library = library
        self.recents = recents
        self.choose = choose
        self.cancel = cancel
        self.openApp = openApp
        _expanded = State(initialValue: Set(library.allFolders.map(\.id)))
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var entries: [ConnectionEntry] { ConnectionFilter.entries(library) }
    private var found: [ConnectionEntry] { ConnectionFilter.filter(entries, query: query, recents: recents) }
    private var shortlist: (favorites: [ConnectionEntry], recent: [ConnectionEntry]) {
        ConnectionFilter.shortlist(entries, recents: recents)
    }
    private var tree: [ConnectionTreeRow] { ConnectionTreeRow.rows(library, expanded: expanded) }
    private var ids: [LauncherRow] {
        if searching { return found.map { .tree($0.connection.id) } }
        let list = shortlist
        return list.favorites.map { .favorite($0.connection.id) } + list.recent.map { .recent($0.connection.id) }
            + tree.map { .tree($0.id) }
    }
    private var current: LauncherRow? { ids.contains { $0 == selected } ? selected : ids.first }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search connections", text: $query)
                .textFieldStyle(.plain)
                .font(.title2)
                .padding(14)
                .focused($focused)
                .onSubmit(activate)
            Divider()
            if library.allConnections.isEmpty {
                VStack(spacing: 12) {
                    Text("No connections yet").foregroundStyle(.secondary)
                    Button("Open xpnd", action: openApp)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selected) {
                        if searching {
                            ForEach(found, id: \.connection.id) { entryRow($0, .tree($0.connection.id)) }
                        } else {
                            let list = shortlist
                            if list.favorites.isEmpty && list.recent.isEmpty {
                                treeRows
                            } else {
                                if !list.favorites.isEmpty {
                                    Section("Favorites") {
                                        ForEach(list.favorites, id: \.connection.id) { entryRow($0, .favorite($0.connection.id)) }
                                    }
                                }
                                if !list.recent.isEmpty {
                                    Section("Recent") {
                                        ForEach(list.recent, id: \.connection.id) { entryRow($0, .recent($0.connection.id)) }
                                    }
                                }
                                Section("All Connections") { treeRows }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: selected) { _, row in if let row { proxy.scrollTo(row) } }
                }
            }
        }
        .frame(width: 560, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .onAppear { focused = true; selected = ids.first }
        .onChange(of: query) { selected = ids.first }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { searching ? .ignored : expand() }
        .onKeyPress(.leftArrow) { searching ? .ignored : collapseOrAscend() }
        .onKeyPress(.escape) { cancel(); return .handled }
        .onKeyPress(keys: [.return], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            activate()
            return .handled
        }
    }

    private var treeRows: some View {
        ForEach(tree) { row in treeRow(row).tag(LauncherRow.tree(row.id)).id(LauncherRow.tree(row.id)) }
    }

    private func entryRow(_ entry: ConnectionEntry, _ row: LauncherRow) -> some View {
        HStack {
            Text(entry.connection.name).lineLimit(1).foregroundStyle(entry.color?.ui ?? Color.primary)
            Spacer()
            Text(entry.pathText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .tag(row)
        .id(row)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { pick(entry.connection.id) }
    }

    private func treeRow(_ row: ConnectionTreeRow) -> some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .folder(let open):
                Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 14).accessibilityHidden(true)
                Image(systemName: row.icon.symbol).accessibilityHidden(true)
            case .connection(let c):
                Image(systemName: c.type.symbol).frame(width: 14).accessibilityHidden(true)
            }
            Text(row.title).lineLimit(1).foregroundStyle(row.color?.ui ?? Color.primary)
            Spacer()
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activate(row) }
    }

    private func activate() {
        switch current {
        case .favorite(let id)?, .recent(let id)?: pick(id)
        case .tree(let id)?:
            if searching { pick(id) } else if let row = tree.first(where: { $0.id == id }) { activate(row) }
        case nil: break
        }
    }

    private func pick(_ id: Connection.ID) {
        guard !activated else { return }
        activated = true
        choose(id, commandHeld)
    }

    private func activate(_ row: ConnectionTreeRow) {
        switch row.kind {
        case .connection(let c): pick(c.id)
        case .folder(let open): if open { expanded.remove(row.id) } else { expanded.insert(row.id) }
        }
    }

    private func move(_ delta: Int) {
        let ids = ids
        guard !ids.isEmpty else { return }
        let index = ids.firstIndex { $0 == current } ?? 0
        selected = ids[min(max(index + delta, 0), ids.count - 1)]
    }

    /// The tree row the selection is on, if it's on one.
    private var currentTreeIndex: Int? {
        guard case .tree(let id)? = current else { return nil }
        return tree.firstIndex { $0.id == id }
    }

    private func expand() -> KeyPress.Result {
        if let index = currentTreeIndex, case .folder = tree[index].kind { expanded.insert(tree[index].id) }
        return .handled
    }

    /// ← closes an open folder; otherwise moves to the parent folder.
    private func collapseOrAscend() -> KeyPress.Result {
        let rows = tree
        guard let index = currentTreeIndex else { return .handled }
        if case .folder(true) = rows[index].kind {
            expanded.remove(rows[index].id)
        } else if let parent = ConnectionTreeRow.parent(of: index, in: rows) {
            selected = .tree(rows[parent].id)
        }
        return .handled
    }
}
