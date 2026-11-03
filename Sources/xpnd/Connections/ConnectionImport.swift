import Foundation

enum ConnectionImport {
    private static func custom(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }

    private static func activations(_ library: ConnectionLibrary) -> Set<String> {
        Set(library.allFolders.flatMap { [$0.activation] + $0.connections.map(\.activation) }.compactMap(custom))
    }

    /// Custom activation strings present in both, sorted.
    static func conflicts(incoming: ConnectionLibrary, existing: ConnectionLibrary) -> [String] {
        activations(incoming).intersection(activations(existing)).sorted()
    }

    /// Folders merge by exact name, recursively. `.replace` removes the existing owner of a
    /// conflicting string (a folder owner keeps its contents but loses its string).
    static func merge(_ incoming: ConnectionLibrary, into existing: ConnectionLibrary, choice: ConflictChoice) -> ConnectionLibrary {
        let existingIDs = Set(existing.allFolders.flatMap { [$0.id] + $0.connections.map(\.id) })
        var renamed: [UUID: UUID] = [:]
        func fresh(_ id: UUID) -> UUID {
            guard existingIDs.contains(id) else { return id }
            let new = UUID()
            renamed[id] = new
            return new
        }
        func reid(_ f: ConnectionFolder) -> ConnectionFolder {
            var f = f
            f.id = fresh(f.id)
            for i in f.connections.indices { f.connections[i].id = fresh(f.connections[i].id) }
            f.folders = f.folders.map(reid)
            return f
        }
        func rejump(_ f: ConnectionFolder) -> ConnectionFolder {
            var f = f
            for i in f.connections.indices {
                if case .connection(let id)? = f.connections[i].jumpHost, let new = renamed[id] {
                    f.connections[i].jumpHost = .connection(new)
                }
            }
            f.folders = f.folders.map(rejump)
            return f
        }
        let incomingFolders = incoming.folders.map(reid).map(rejump)

        let blocked = choice == .skip ? activations(existing) : []
        // Removed connection -> the connection that now holds its string.
        var redirect: [UUID: UUID] = [:]
        let existingOwner = Dictionary(
            existing.allConnections.compactMap { c in custom(c.activation).map { ($0, c.id) } },
            uniquingKeysWith: { a, _ in a })
        var adopted = Set<UUID>()
        func dropBlocked(_ list: [Connection]) -> [Connection] {
            list.filter { c in
                guard let a = custom(c.activation), blocked.contains(a) else { return true }
                if let owner = existingOwner[a] { redirect[c.id] = owner }
                return false
            }
        }
        func adopt(_ f: ConnectionFolder) -> ConnectionFolder {
            var f = f
            if let a = custom(f.activation), blocked.contains(a) { f.activation = nil }
            f.connections = dropBlocked(f.connections)
            f.folders = f.folders.map(adopt)
            return f
        }
        func mergeFolders(_ target: inout [ConnectionFolder], _ new: [ConnectionFolder]) {
            for f in new {
                if let i = target.firstIndex(where: { $0.name == f.name }) {
                    target[i].connections += dropBlocked(f.connections)
                    if let a = custom(f.activation), custom(target[i].activation) != a {
                        let clashes = activations(existing).contains(a)
                        if clashes ? choice == .replace : custom(target[i].activation) == nil {
                            target[i].activation = a
                            adopted.insert(target[i].id)
                        }
                    }
                    mergeFolders(&target[i].folders, f.folders)
                } else {
                    target.append(adopt(f))
                }
            }
        }
        var result = existing
        mergeFolders(&result.folders, incomingFolders)

        if choice == .replace {
            // Anything not carrying an original ID is incoming; its strings evict the original owners.
            var claimedConn: [String: UUID] = [:]
            for f in result.allFolders {
                for c in f.connections where !existingIDs.contains(c.id) {
                    if let a = custom(c.activation) { claimedConn[a] = c.id }
                }
            }
            let claimed = Set(result.allFolders.flatMap { f in
                (existingIDs.contains(f.id) && !adopted.contains(f.id) ? [] : [f.activation])
                    + f.connections.filter { !existingIDs.contains($0.id) }.map(\.activation)
            }.compactMap(custom))
            func evict(_ f: inout ConnectionFolder) {
                if existingIDs.contains(f.id), !adopted.contains(f.id),
                   let a = custom(f.activation), claimed.contains(a) { f.activation = "" }
                f.connections.removeAll { c in
                    guard existingIDs.contains(c.id), let a = custom(c.activation), claimed.contains(a) else { return false }
                    if let survivor = claimedConn[a] { redirect[c.id] = survivor }
                    return true
                }
                for i in f.folders.indices { evict(&f.folders[i]) }
            }
            for i in result.folders.indices { evict(&result.folders[i]) }
        }
        // Repoint jumps that referenced a removed connection.
        func repoint(_ f: inout ConnectionFolder) {
            for i in f.connections.indices {
                if case .connection(let id)? = f.connections[i].jumpHost, let to = redirect[id] {
                    f.connections[i].jumpHost = .connection(to)
                }
            }
            for i in f.folders.indices { repoint(&f.folders[i]) }
        }
        if !redirect.isEmpty { for i in result.folders.indices { repoint(&result.folders[i]) } }
        return result
    }

    /// Hosts of the incoming connections the merge with `choice` would add, sorted and unique.
    static func hostsAdded(incoming: ConnectionLibrary, existing: ConnectionLibrary, choice: ConflictChoice) -> [String] {
        Set(previewRows(incoming: incoming, existing: existing, choice: choice).map(\.host)).sorted()
    }

    /// One connection the merge would add, as the import confirmation shows it.
    struct PreviewRow: Identifiable, Equatable {
        let id: Connection.ID
        let name: String
        let host: String
        /// `user@host:port`, without `user@` when no user resolves.
        let address: String
        /// The text, or the saved connection's name; nil for none.
        let jumpHost: String?
        /// Verbatim, since they run on connect.
        let sshOptions: String
    }

    /// `text` with every control and format character shown, so a newline, escape or bidi override
    /// can't hide part of an option in the import preview.
    static func visible(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out += "⏎"
            case "\t": out += "⇥"
            // C0 and DEL have Control Pictures: ␛, ␍, ␀…
            case "\u{0}"..."\u{1F}": out.unicodeScalars.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case "\u{7F}": out += "␡"
            default:
                switch scalar.properties.generalCategory {
                case .control, .format: out += "<U+\(String(scalar.value, radix: 16, uppercase: true))>"
                default: out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// The connections the merge with `choice` would add, in tree order.
    static func previewRows(incoming: ConnectionLibrary, existing: ConnectionLibrary, choice: ConflictChoice) -> [PreviewRow] {
        let have = Set(existing.allConnections.map(\.id))
        // Colliding incoming IDs are re-keyed, so every added connection is outside `have`.
        let merged = merge(incoming, into: existing, choice: choice)
        return merged.allConnections.filter { !have.contains($0.id) }.map { c in
            let jump: String? = switch c.jumpHost {
            case nil: nil
            case .text(let text): text
            case .connection(let id): merged.connection(id)?.name ?? "A missing connection"
            }
            let user = merged.loginUser(for: c).map { "\($0)@" } ?? ""
            let host = c.host.contains(":") && !c.host.hasPrefix("[") ? "[\(c.host)]" : c.host
            return PreviewRow(id: c.id, name: c.name, host: c.host, address: "\(user)\(host):\(c.effectivePort)",
                              jumpHost: jump, sshOptions: c.sshOptions)
        }
    }

    /// `folders == nil` exports everything; selected folders keep their whole subtree.
    static func export(_ library: ConnectionLibrary, folders: Set<ConnectionFolder.ID>?) -> String {
        guard let folders else { return ConnectionYAML.encode(library) }
        func pick(_ list: [ConnectionFolder]) -> [ConnectionFolder] {
            list.flatMap { folders.contains($0.id) ? [$0] : pick($0.folders) }
        }
        return ConnectionYAML.encode(ConnectionLibrary(folders: pick(library.folders)))
    }
}
