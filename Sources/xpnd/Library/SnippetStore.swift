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
}
