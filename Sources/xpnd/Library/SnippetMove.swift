import Foundation

extension SnippetLibrary {
    /// Moves a snippet into `group` at `index`, counted among the group's snippets before the move
    /// (as a drop between rows reports it); nil appends. False, and no change, if either is missing.
    @discardableResult
    mutating func moveSnippet(_ id: Snippet.ID, to group: SnippetGroup.ID, at index: Int?) -> Bool {
        guard let gi = groups.firstIndex(where: { $0.id == group }),
              let fromGroup = groups.firstIndex(where: { $0.snippets.contains { $0.id == id } }),
              let fromIndex = groups[fromGroup].snippets.firstIndex(where: { $0.id == id }) else { return false }
        let snippet = groups[fromGroup].snippets.remove(at: fromIndex)
        let target = index.map { fromGroup == gi && fromIndex < $0 ? $0 - 1 : $0 } ?? groups[gi].snippets.count
        groups[gi].snippets.insert(snippet, at: min(target, groups[gi].snippets.count))
        return true
    }

    /// Reorders a group to `index`, counted before the move.
    @discardableResult
    mutating func moveGroup(_ id: SnippetGroup.ID, to index: Int) -> Bool {
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return false }
        let group = groups.remove(at: from)
        groups.insert(group, at: min(from < index ? index - 1 : index, groups.count))
        return true
    }
}
