import Foundation
import Yams

enum ConnectionYAMLError: Error, Equatable {
    case malformed(String)
    case unsupportedVersion(Int)
    case duplicateIDs([String])
}

enum ConnectionYAML {
    static let currentVersion = 1

    private struct File: Codable {
        var version: Int?
        var credential: CredentialRef?
        var sudoCredential: CredentialRef?
        var folders: [Folder]?
    }

    private struct Folder: Codable {
        var id: UUID?
        var name: String
        var activation: String?
        var credential: CredentialRef?
        var sudoCredential: CredentialRef?
        var color: ItemColor?
        var connections: [Item]?
        var folders: [Folder]?
    }

    private struct Item: Codable {
        var id: UUID?
        var name: String
        var type: ConnectionType?
        var host: String
        var port: Int?
        var username: String?
        var activation: String?
        var credential: CredentialRef?
        var sudoCredential: CredentialRef?
        var color: ItemColor?
        var advanced: Advanced?
    }

    private struct Advanced: Codable {
        var jumpHost: Jump?
        var sshOptions: String?
        var autoSudo: Bool?
    }

    private struct Jump: Codable {
        var connection: UUID?
        var text: String?
    }

    static func decode(_ yaml: String) throws(ConnectionYAMLError) -> ConnectionLibrary {
        let file: File
        do {
            // An empty document decodes to nil; treat it as an empty library.
            file = try YAMLDecoder().decode(File?.self, from: yaml) ?? File()
        } catch {
            throw .malformed(String(describing: error))
        }
        let version = file.version ?? currentVersion
        guard version == currentVersion else { throw .unsupportedVersion(version) }
        let library = ConnectionLibrary(credential: file.credential, sudoCredential: file.sudoCredential,
                                        folders: (file.folders ?? []).map(model))
        var seen = Set<UUID>()
        var dupes: [String] = []
        func visit(_ f: ConnectionFolder) {
            for id in [f.id] + f.connections.map(\.id) where !seen.insert(id).inserted {
                dupes.append(id.uuidString)
            }
            f.folders.forEach(visit)
        }
        library.folders.forEach(visit)
        guard dupes.isEmpty else { throw .duplicateIDs(dupes) }
        return library
    }

    private static func model(_ f: Folder) -> ConnectionFolder {
        ConnectionFolder(
            id: f.id ?? UUID(), name: f.name, activation: f.activation,
            credential: f.credential, sudoCredential: f.sudoCredential,
            connections: (f.connections ?? []).map { c in
                let jump: JumpHost? = c.advanced?.jumpHost.flatMap {
                    $0.connection.map(JumpHost.connection) ?? $0.text.map(JumpHost.text)
                }
                return Connection(
                    id: c.id ?? UUID(), name: c.name, type: c.type ?? .ssh, host: c.host, port: c.port,
                    username: c.username, activation: c.activation, credential: c.credential,
                    sudoCredential: c.sudoCredential, jumpHost: jump,
                    sshOptions: c.advanced?.sshOptions ?? "", autoSudo: c.advanced?.autoSudo ?? false, color: c.color)
            },
            folders: (f.folders ?? []).map(model), color: f.color)
    }

    private static func dto(_ f: ConnectionFolder) -> Folder {
        Folder(
            id: f.id, name: f.name, activation: f.activation,
            credential: f.credential, sudoCredential: f.sudoCredential, color: f.color,
            connections: f.connections.isEmpty ? nil : f.connections.map { c in
                let jump: Jump? = switch c.jumpHost {
                case .connection(let id): Jump(connection: id)
                case .text(let t): Jump(text: t)
                case nil: nil
                }
                let advanced = Advanced(jumpHost: jump,
                                        sshOptions: c.sshOptions.isEmpty ? nil : c.sshOptions,
                                        autoSudo: c.autoSudo ? true : nil)
                let hasAdvanced = jump != nil || advanced.sshOptions != nil || c.autoSudo
                return Item(id: c.id, name: c.name, type: c.type, host: c.host, port: c.port,
                            username: c.username, activation: c.activation, credential: c.credential,
                            sudoCredential: c.sudoCredential, color: c.color, advanced: hasAdvanced ? advanced : nil)
            },
            folders: f.folders.isEmpty ? nil : f.folders.map(dto))
    }

    static func encode(_ library: ConnectionLibrary) -> String {
        let file = File(version: currentVersion, credential: library.credential,
                        sudoCredential: library.sudoCredential,
                        folders: library.folders.isEmpty ? nil : library.folders.map(dto))
        let encoder = YAMLEncoder()
        encoder.options.newLineScalarStyle = .literal
        // Plain strings/bools/enums can't fail to encode, so the fallback is unreachable.
        return (try? encoder.encode(file)) ?? ""
    }
}
