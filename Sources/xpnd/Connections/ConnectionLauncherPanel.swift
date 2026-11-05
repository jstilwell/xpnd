import AppKit
import SwiftUI

/// The search panel the connection hotkey opens: type to filter (or browse the folder tree when the
/// query is empty), Return to connect, Esc to close.
@MainActor
final class ConnectionLauncherPanel: LauncherPanel {
    func toggle(
        library: ConnectionLibrary,
        onOpenApp: @escaping () -> Void,
        connect: @escaping (Connection.ID, pid_t?, _ sudo: Bool) async -> Void
    ) {
        if isVisible { close(); return }
        // A fresh view each time, so the query and highlight start clean.
        present(ConnectionLauncherView(
            library: library,
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

private struct ConnectionLauncherView: View {
    let library: ConnectionLibrary
    let choose: (Connection.ID, _ sudo: Bool) -> Void
    let cancel: () -> Void
    let openApp: () -> Void
    /// ⌘ on Return, keypad Enter or a double-click connects with sudo.
    private var commandHeld: Bool { NSEvent.modifierFlags.contains(.command) }
    /// Return with ⌘ may reach both the field's submit and the key handler; the first one wins.
    @State private var activated = false
    @State private var query = ""
    @State private var selected: UUID?
    @State private var expanded: Set<ConnectionFolder.ID>
    @FocusState private var focused: Bool

    init(
        library: ConnectionLibrary, choose: @escaping (Connection.ID, _ sudo: Bool) -> Void,
        cancel: @escaping () -> Void, openApp: @escaping () -> Void
    ) {
        self.library = library
        self.choose = choose
        self.cancel = cancel
        self.openApp = openApp
        _expanded = State(initialValue: Set(library.allFolders.map(\.id)))
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var found: [ConnectionEntry] { ConnectionFilter.filter(ConnectionFilter.entries(library), query: query) }
    private var tree: [ConnectionTreeRow] { ConnectionTreeRow.rows(library, expanded: expanded) }
    private var ids: [UUID] { searching ? found.map(\.connection.id) : tree.map(\.id) }
    private var current: UUID? { ids.contains { $0 == selected } ? selected : ids.first }

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
                            ForEach(found, id: \.connection.id) { entry in
                                HStack {
                                    Text(entry.connection.name).lineLimit(1).foregroundStyle(entry.color?.ui ?? Color.primary)
                                    Spacer()
                                    Text(entry.pathText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .tag(entry.connection.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { pick(entry.connection.id) }
                            }
                        } else {
                            ForEach(tree) { row in
                                treeRow(row).tag(row.id)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: selected) { _, id in if let id { proxy.scrollTo(id) } }
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

    private func treeRow(_ row: ConnectionTreeRow) -> some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .folder(let open):
                Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 14).accessibilityHidden(true)
                Image(systemName: "folder").accessibilityHidden(true)
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
        if searching { if let id = current { pick(id) } } else if let row = tree.first(where: { $0.id == current }) { activate(row) }
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

    private func expand() -> KeyPress.Result {
        if let row = tree.first(where: { $0.id == current }), case .folder = row.kind { expanded.insert(row.id) }
        return .handled
    }

    /// ← closes an open folder; otherwise moves to the parent folder.
    private func collapseOrAscend() -> KeyPress.Result {
        let rows = tree
        guard let index = rows.firstIndex(where: { $0.id == current }) else { return .handled }
        if case .folder(true) = rows[index].kind {
            expanded.remove(rows[index].id)
        } else if let parent = ConnectionTreeRow.parent(of: index, in: rows) {
            selected = rows[parent].id
        }
        return .handled
    }
}
