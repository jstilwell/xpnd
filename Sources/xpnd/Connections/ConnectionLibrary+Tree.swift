import Foundation

enum CredentialSource: Equatable {
    /// `.login`: the sudo credential fell back to the login credential.
    case connection, folder(name: String), global, login
}

struct ResolvedCredential: Equatable {
    let ref: CredentialRef
    let source: CredentialSource
}

extension ConnectionFolder {
    /// `;` + the name lowercased with whitespace removed; "" when nothing is left.
    static func derivedActivation(for name: String) -> String {
        let stem = name.lowercased().filter { !$0.isWhitespace }
        return stem.isEmpty ? "" : ";" + stem
    }

    /// Tree order: this folder's connections, then its subfolders, depth-first.
    var allConnections: [Connection] { connections + folders.flatMap(\.allConnections) }
    /// Tree order: this folder, then its subfolders, depth-first.
    var allFolders: [ConnectionFolder] { [self] + folders.flatMap(\.allFolders) }

    fileprivate func path(of id: Connection.ID) -> [ConnectionFolder]? {
        if connections.contains(where: { $0.id == id }) { return [self] }
        return folders.lazy.compactMap { $0.path(of: id) }.first.map { [self] + $0 }
    }
}

extension ConnectionLibrary {
    var allConnections: [Connection] { folders.flatMap(\.allConnections) }
    var allFolders: [ConnectionFolder] { folders.flatMap(\.allFolders) }

    func connection(_ id: Connection.ID) -> Connection? { allConnections.first { $0.id == id } }
    func folder(_ id: ConnectionFolder.ID) -> ConnectionFolder? { allFolders.first { $0.id == id } }

    /// The connection's ancestor folders, from the root.
    func path(of id: Connection.ID) -> [ConnectionFolder] {
        folders.lazy.compactMap { $0.path(of: id) }.first ?? []
    }

    func loginCredential(for id: Connection.ID) -> ResolvedCredential? {
        resolve(id, \.credential, \.credential, global: credential)
    }

    func sudoCredential(for id: Connection.ID) -> ResolvedCredential? {
        if let sudo = resolve(id, \.sudoCredential, \.sudoCredential, global: sudoCredential) { return sudo }
        guard let login = loginCredential(for: id), login.ref.hasPassword else { return nil }
        return ResolvedCredential(ref: login.ref, source: .login)
    }

    /// The connection's own username, else the resolved credential's.
    func loginUser(for connection: Connection) -> String? {
        [connection.username, loginCredential(for: connection.id)?.ref.username].compactMap { $0 }.first { !$0.isEmpty }
    }

    /// Connection, then the nearest folder, then global.
    private func resolve(
        _ id: Connection.ID,
        _ own: KeyPath<Connection, CredentialRef?>,
        _ inherited: KeyPath<ConnectionFolder, CredentialRef?>,
        global: CredentialRef?
    ) -> ResolvedCredential? {
        guard let connection = connection(id) else { return nil }
        if let ref = connection[keyPath: own] { return ResolvedCredential(ref: ref, source: .connection) }
        for folder in path(of: id).reversed() {
            if let ref = folder[keyPath: inherited] { return ResolvedCredential(ref: ref, source: .folder(name: folder.name)) }
        }
        return global.map { ResolvedCredential(ref: $0, source: .global) }
    }
}
