import Foundation

struct ConnectionEntry: Hashable {
    let connection: Connection
    /// Ancestor folder names, from the root.
    let path: [String]
    /// Its own color, or the nearest folder's.
    let color: ItemColor?

    var pathText: String { path.joined(separator: " › ") }
}

enum ConnectionFilter {
    /// Every connection in tree order.
    static func entries(_ library: ConnectionLibrary) -> [ConnectionEntry] {
        // `inherited` is the nearest coloured ancestor's, as `library.color(for:)` finds it.
        func walk(_ folder: ConnectionFolder, _ parents: [String], _ inherited: ItemColor?) -> [ConnectionEntry] {
            let path = parents + [folder.name], color = folder.color ?? inherited
            return folder.connections.map { ConnectionEntry(connection: $0, path: path, color: $0.color ?? color) }
                + folder.folders.flatMap { walk($0, path, color) }
        }
        return library.folders.flatMap { walk($0, [], nil) }
    }

    /// Empty query: tree order. Otherwise 0: name starts with it; 1: name, activation string or host
    /// contains it; 2: folder path contains it. Ties by name.
    static func filter(_ entries: [ConnectionEntry], query: String) -> [ConnectionEntry] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func has(_ s: String) -> Bool { s.range(of: query, options: options) != nil }
        func rank(_ e: ConnectionEntry) -> Int? {
            if e.connection.name.range(of: query, options: options.union(.anchored)) != nil { return 0 }
            if has(e.connection.name) || has(e.connection.activation ?? "") || has(e.connection.host) { return 1 }
            return has(e.pathText) ? 2 : nil
        }
        let ranked = entries.compactMap { e in rank(e).map { (entry: e, rank: $0) } }
        let sorted = ranked.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return a.entry.connection.name.localizedStandardCompare(b.entry.connection.name) == .orderedAscending
        }
        return sorted.map(\.entry)
    }
}

/// One line of the launcher's tree.
struct ConnectionTreeRow: Identifiable, Hashable {
    enum Kind: Hashable { case folder(expanded: Bool), connection(Connection) }
    let id: UUID
    let title: String
    let depth: Int
    let kind: Kind
    let color: ItemColor?
    var icon: FolderIcon? = nil

    /// Folders and connections in tree order; a folder's contents show only while it is in `expanded`.
    static func rows(_ library: ConnectionLibrary, expanded: Set<ConnectionFolder.ID>) -> [ConnectionTreeRow] {
        func walk(_ folder: ConnectionFolder, _ depth: Int, _ inherited: ItemColor?) -> [ConnectionTreeRow] {
            let open = expanded.contains(folder.id), color = folder.color ?? inherited
            let head = ConnectionTreeRow(id: folder.id, title: folder.name, depth: depth, kind: .folder(expanded: open),
                                         color: color, icon: folder.icon)
            guard open else { return [head] }
            return [head]
                + folder.connections.map {
                    ConnectionTreeRow(id: $0.id, title: $0.name, depth: depth + 1, kind: .connection($0), color: $0.color ?? color)
                }
                + folder.folders.flatMap { walk($0, depth + 1, color) }
        }
        return library.folders.flatMap { walk($0, 0, nil) }
    }

    /// The index of the nearest folder row above `index` that is shallower.
    static func parent(of index: Int, in rows: [ConnectionTreeRow]) -> Int? {
        rows[..<index].lastIndex { $0.depth < rows[index].depth }
    }
}
