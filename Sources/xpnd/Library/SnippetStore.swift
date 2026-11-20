import Foundation

typealias SnippetStore = YAMLFileStore<SnippetLibrary>

extension YAMLFileStore where Value == SnippetLibrary {
    nonisolated static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "xpnd/snippets.yaml")
    }

    convenience init(fileURL: URL) {
        self.init(
            fileURL: fileURL, empty: .empty,
            decode: SnippetYAML.decode, encode: SnippetYAML.encode,
            duplicate: { $0.duplicateKeywords.first })
    }

    var library: SnippetLibrary { value }

    /// One starter snippet, once, so a new user has something to type.
    func seedIfFirstLaunch(defaults: UserDefaults) {
        seedIfFirstLaunch(defaults: defaults, key: "snippetsSeeded", with: .starter())
    }
}

extension SnippetLibrary {
    static func starter() -> SnippetLibrary {
        SnippetLibrary(groups: [SnippetGroup(name: "Starter", snippets: [Snippet(name: "Today's date", keyword: ";date", text: "#{date}")])])
    }
}
