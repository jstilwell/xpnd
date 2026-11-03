import Foundation

typealias ConnectionStore = YAMLFileStore<ConnectionLibrary>

extension ConnectionLibrary {
    /// Custom (non-empty) activation strings, connections and folders together, in tree order.
    fileprivate var customActivations: [String] {
        allFolders.flatMap { f in [f.activation] + f.connections.map(\.activation) }
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// The first duplicate ID, else the first duplicate custom activation string.
    fileprivate var firstDuplicate: String? {
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

    /// Writes the dev/prod starter folders once; deleting the file later never re-seeds.
    func seedIfFirstLaunch(defaults: UserDefaults) {
        let key = "connectionsSeeded"
        guard !defaults.bool(forKey: key) else { return }
        if !fileExists {
            // A failed write leaves the flag unset so the next launch retries.
            do { try update { $0 = .starter() } } catch { return }
        }
        defaults.set(true, forKey: key)
    }
}
