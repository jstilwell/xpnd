import Foundation

extension FolderIcon {
    var symbolName: String {
        switch self {
        case .terminal: "terminal"
        case .windows: "pc"
        case .desktop: "desktopcomputer"
        case .server: "server.rack"
        case .network: "network"
        case .cloud: "cloud"
        case .shield: "lock.shield"
        case .home: "house"
        case .building: "building.2"
        }
    }

    var label: String {
        switch self {
        case .terminal: "Terminal (Linux, SSH)"
        case .windows: "PC (Windows, RDP)"
        case .desktop: "Desktop"
        case .server: "Server rack"
        case .network: "Network"
        case .cloud: "Cloud"
        case .shield: "Shield"
        case .home: "Home"
        case .building: "Building"
        }
    }
}

extension FolderIcon? {
    /// The folder's symbol; the plain folder when it has no icon.
    var symbol: String { map(\.symbolName) ?? "folder" }
}
