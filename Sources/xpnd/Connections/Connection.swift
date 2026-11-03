import Foundation

enum ConnectionType: String, Codable, Sendable {
    case ssh, vnc

    var defaultPort: Int { self == .ssh ? 22 : 5900 }
}

enum CredentialCategory: String, Codable, Sendable {
    case sshKey = "ssh_key", login, password, server
}

struct CredentialRef: Hashable, Codable, Sendable {
    var provider = "1password"
    var account: String
    var vault: String
    var item: String
    var title: String
    var category: CredentialCategory
    var username: String?

    var hasPassword: Bool { category != .sshKey }

    /// Refs come from a hand-editable file: a leading "-" would become a CLI flag, and a "/" would
    /// leave the keys directory.
    static func isSafe(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first.isASCII, first.properties.isAlphabetic || ("0"..."9").contains(Character(first))
        else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains(Character($0)) || ".-_".unicodeScalars.contains($0)) }
    }
}

enum JumpHost: Hashable, Sendable {
    case connection(UUID), text(String)
}

struct Connection: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var type: ConnectionType = .ssh
    var host: String
    /// nil means the type's default port.
    var port: Int?
    var username: String?
    var activation: String?
    var credential: CredentialRef?
    var sudoCredential: CredentialRef?
    var jumpHost: JumpHost?
    var sshOptions = ""
    var autoSudo = false

    var effectivePort: Int { port ?? type.defaultPort }
}

struct ConnectionFolder: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// nil means derived from the name; "" means none.
    var activation: String?
    var credential: CredentialRef?
    var sudoCredential: CredentialRef?
    var connections: [Connection] = []
    var folders: [ConnectionFolder] = []
}

struct ConnectionLibrary: Hashable, Sendable {
    var credential: CredentialRef?
    var sudoCredential: CredentialRef?
    var folders: [ConnectionFolder]

    static let empty = ConnectionLibrary(folders: [])

    static func starter() -> ConnectionLibrary {
        ConnectionLibrary(folders: [ConnectionFolder(name: "dev"), ConnectionFolder(name: "prod")])
    }
}
