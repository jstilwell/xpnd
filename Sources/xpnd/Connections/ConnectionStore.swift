import Foundation

typealias ConnectionStore = YAMLFileStore<ConnectionLibrary>

extension ConnectionLibrary {
    /// Custom (non-empty) activation strings, connections and folders together, in tree order.
    fileprivate var customActivations: [String] {
        allFolders.flatMap { f in [f.activation] + f.connections.map(\.activation) }
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// The first duplicate ID, else the first duplicate custom activation string.
    var firstDuplicate: String? {
        func first(_ items: [String]) -> String? {
            var seen = Set<String>()
            return items.first { !seen.insert($0).inserted }
        }
        return first(allFolders.flatMap { [$0.id] + $0.connections.map(\.id) }.map(\.uuidString))
            ?? first(customActivations)
    }
}

extension YAMLFileStore where Value == ConnectionLibrary {
    nonisolated static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "xpnd/connections.yaml")
    }

    convenience init(fileURL: URL) {
        self.init(
            fileURL: fileURL, empty: .empty,
            decode: ConnectionYAML.decode, encode: ConnectionYAML.encode,
            duplicate: { $0.firstDuplicate })
    }

    var library: ConnectionLibrary { value }

    /// The dev/prod starter folders, once.
    func seedIfFirstLaunch(defaults: UserDefaults) {
        seedIfFirstLaunch(defaults: defaults, key: "connectionsSeeded", with: .starter())
    }
}
