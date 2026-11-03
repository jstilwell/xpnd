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
        func adopt(_ f: ConnectionFolder) -> ConnectionFolder {
            var f = f
            if let a = custom(f.activation), blocked.contains(a) { f.activation = nil }
            f.connections.removeAll { custom($0.activation).map(blocked.contains) ?? false }
            f.folders = f.folders.map(adopt)
            return f
        }
        func mergeFolders(_ target: inout [ConnectionFolder], _ new: [ConnectionFolder]) {
            for f in new {
                if let i = target.firstIndex(where: { $0.name == f.name }) {
                    target[i].connections += f.connections.filter { custom($0.activation).map(blocked.contains) != true }
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
            let claimed = Set(result.allFolders.flatMap { f in
                (existingIDs.contains(f.id) ? [] : [f.activation])
                    + f.connections.filter { !existingIDs.contains($0.id) }.map(\.activation)
            }.compactMap(custom))
            func evict(_ f: inout ConnectionFolder) {
                if existingIDs.contains(f.id), let a = custom(f.activation), claimed.contains(a) { f.activation = "" }
                f.connections.removeAll {
                    existingIDs.contains($0.id) && (custom($0.activation).map(claimed.contains) ?? false)
                }
                for i in f.folders.indices { evict(&f.folders[i]) }
            }
            for i in result.folders.indices { evict(&result.folders[i]) }
        }
        return result
    }

    /// Hosts of the incoming connections a merge would add, sorted and unique.
    static func hostsAdded(incoming: ConnectionLibrary, existing: ConnectionLibrary) -> [String] {
        let have = Set(existing.allConnections.map(\.id))
        // Replace adds every incoming connection; colliding IDs were re-keyed, so none is in `have`.
        let merged = merge(incoming, into: existing, choice: .replace)
        return Set(merged.allConnections.filter { !have.contains($0.id) }.map(\.host)).sorted()
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
