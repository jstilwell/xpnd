import Foundation

enum MatchingMode: String, Codable, Sendable { case strict, loose }

struct Snippet: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var keyword: String
    var matching: MatchingMode = .strict
    var enabled = true
    var text: String
}

struct SnippetGroup: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var description = ""
    var enabled = true
    var snippets: [Snippet]
}

struct SnippetLibrary: Hashable, Sendable {
    var groups: [SnippetGroup]

    static let empty = SnippetLibrary(groups: [])

    /// Enabled snippets in enabled groups.
    var activeSnippets: [Snippet] {
        groups.filter(\.enabled).flatMap(\.snippets).filter(\.enabled)
    }

    /// Includes disabled snippets, so helpers used only via `#{combo:}` can stay off.
    func snippet(keyword: String) -> Snippet? {
        groups.lazy.flatMap(\.snippets).first { $0.keyword == keyword }
    }

    var duplicateKeywords: [String] {
        let counts = Dictionary(grouping: groups.flatMap(\.snippets), by: \.keyword).mapValues(\.count)
        return counts.filter { $0.value > 1 }.keys.sorted()
    }
}
