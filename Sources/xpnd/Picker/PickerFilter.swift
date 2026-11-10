import Foundation

enum PickerFilter {
    /// `snippets` is taken as given: the picker passes `library.activeSnippets`, so disabled ones never show
    /// there, and the sidebar a whole group, disabled ones included.
    static func filter(_ snippets: [Snippet], query: String) -> [Snippet] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let byName: (Snippet, Snippet) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !query.isEmpty else { return snippets.sorted(by: byName) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func has(_ s: String) -> Bool { s.range(of: query, options: options) != nil }
        /// 0: keyword starts with it. 1: keyword or name contains it. 2: text contains it.
        func rank(_ s: Snippet) -> Int? {
            if s.keyword.range(of: query, options: options.union(.anchored)) != nil { return 0 }
            if has(s.keyword) || has(s.name) { return 1 }
            return has(s.text) ? 2 : nil
        }
        return snippets.compactMap { s in rank(s).map { (s, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : byName($0.0, $1.0) }
            .map(\.0)
    }
}
