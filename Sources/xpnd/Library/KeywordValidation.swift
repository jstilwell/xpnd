import Foundation

extension SnippetLibrary {
    /// Why `keyword` can't be used by the snippet `snippet` (nil for a new one), or nil if it can.
    func keywordProblem(_ keyword: String, for snippet: Snippet.ID?) -> String? {
        if keyword.isEmpty { return "Keyword can't be empty" }
        // Space, tab, and return reset the typing buffer, so such a keyword could never match.
        if keyword.contains(where: \.isWhitespace) { return "Keywords can't contain spaces or tabs" }
        // The buffer counts Characters, so this does too.
        if keyword.count > TypingBuffer.capacity { return "Keywords can be at most \(TypingBuffer.capacity) characters" }
        if let owner = groups.lazy.flatMap(\.snippets).first(where: { $0.keyword == keyword && $0.id != snippet }) {
            return "“\(keyword)” is already used by “\(owner.name)”"
        }
        return nil
    }
}
