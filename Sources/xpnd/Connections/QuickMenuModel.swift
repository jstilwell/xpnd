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
        let items: [(String, QuickMenuRow.Kind, ActivationTarget)] =
            folder.connections.map { ($0.name, .connection($0.id, $0.type), .connection($0.id)) }
            + folder.folders.map { ($0.name, .folder($0.id), .folder($0.id)) }
        return items.enumerated().map {
            QuickMenuRow(number: $0 < 9 ? $0 + 1 : nil, title: $1.0, kind: $1.1, color: library.color(for: $1.2)?.color)
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
