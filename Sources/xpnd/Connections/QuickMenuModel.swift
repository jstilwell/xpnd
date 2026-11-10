import Foundation

struct QuickMenuRow: Hashable {
    enum Kind: Hashable {
        case connection(Connection.ID, ConnectionType)
        case folder(ConnectionFolder.ID)
    }

    /// 1–9 for the first nine rows, else nil.
    let number: Int?
    let title: String
    let kind: Kind
    let color: ItemColor?
    /// A folder's own icon; nil for a connection or a plain folder.
    var icon: FolderIcon? = nil
}

/// What the quick menu shows: one folder's connections, then its subfolders, with a back stack for subfolders.
struct QuickMenuModel {
    private let library: ConnectionLibrary
    private var stack: [ConnectionFolder.ID]

    init(library: ConnectionLibrary, folder: ConnectionFolder.ID) {
        self.library = library
        stack = [folder]
    }

    private var current: ConnectionFolder? { library.folder(stack.last!) }

    /// A folder deleted since the string was typed shows as an empty "Connections" menu.
    var title: String { current?.name ?? "Connections" }
    var canGoBack: Bool { stack.count > 1 }

    var rows: [QuickMenuRow] {
        guard let folder = current else { return [] }
        // One lookup for the folder; everything in it without a colour of its own takes that.
        let inherited = library.color(for: .folder(folder.id))?.color
        let items: [(String, QuickMenuRow.Kind, ItemColor?, FolderIcon?)] =
            folder.connections.map { ($0.name, .connection($0.id, $0.type), $0.color, nil) }
            + folder.folders.map { ($0.name, .folder($0.id), $0.color, $0.icon) }
        return items.enumerated().map {
            QuickMenuRow(number: $0 < 9 ? $0 + 1 : nil, title: $1.0, kind: $1.1, color: $1.2 ?? inherited, icon: $1.3)
        }
    }

    func row(number: Int) -> QuickMenuRow? { rows.first { $0.number == number } }

    /// A connection's ID to connect to, or nil after opening a folder in place.
    mutating func choose(_ row: QuickMenuRow) -> Connection.ID? {
        switch row.kind {
        case .connection(let id, _): return id
        case .folder(let id): stack.append(id); return nil
        }
    }

    mutating func back() { if canGoBack { stack.removeLast() } }
}
