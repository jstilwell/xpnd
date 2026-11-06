import Foundation

enum ConnectionType: String, Codable, Sendable {
    case ssh, vnc, rdp

    var defaultPort: Int {
        switch self {
        case .ssh: 22
        case .vnc: 5900
        case .rdp: 3389
        }
    }

    var symbol: String {
        switch self {
        case .ssh: "terminal"
        case .vnc: "display"
        case .rdp: "pc"
        }
    }
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

/// A fixed palette, like Finder tags: it reads in light and dark mode and is hand-editable in YAML.
enum ItemColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, purple, gray
}

/// A folder's own symbol, hand-editable in YAML. Subfolders do not inherit it.
enum FolderIcon: String, Codable, CaseIterable, Sendable {
    case terminal, windows, desktop, server, network, cloud, shield, home, building
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
    /// RDP only: the Windows domain for `username`.
    var domain: String?
    var activation: String?
    var credential: CredentialRef?
    var sudoCredential: CredentialRef?
    var jumpHost: JumpHost?
    var sshOptions = ""
    var autoSudo = false
    /// RDP only; nil behaves as empty options.
    var rdp: RDPOptions?
    /// nil inherits the nearest folder's.
    var color: ItemColor?

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
    /// nil inherits the nearest ancestor folder's.
    var color: ItemColor?
    /// nil is the plain folder symbol.
    var icon: FolderIcon?
}

struct ConnectionLibrary: Hashable, Sendable {
    var credential: CredentialRef?
    var sudoCredential: CredentialRef?
    var folders: [ConnectionFolder]
    /// False: sudo no longer falls back to the login credential.
    var sudoUsesLogin = true

    static let empty = ConnectionLibrary(folders: [])

    static func starter() -> ConnectionLibrary {
        ConnectionLibrary(folders: [ConnectionFolder(name: "dev"), ConnectionFolder(name: "prod")])
    }
}
