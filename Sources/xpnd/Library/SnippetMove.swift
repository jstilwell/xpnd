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

/// Where a snippet sat, for undo. A reload gives groups new ids, so the name finds the group then.
struct SnippetPlacement: Equatable {
    let groupID: SnippetGroup.ID
    let groupName: String
    let index: Int
}

extension SnippetLibrary {
    func placement(ofSnippet id: Snippet.ID) -> SnippetPlacement? {
        for group in groups {
            if let index = group.snippets.firstIndex(where: { $0.id == id }) {
                return SnippetPlacement(groupID: group.id, groupName: group.name, index: index)
            }
        }
        return nil
    }

    /// The snippet with `id`, or, after a reload gave it a new one, with `keyword`.
    func snippetID(id: Snippet.ID, keyword: String) -> Snippet.ID? {
        let all = groups.lazy.flatMap(\.snippets)
        return (all.first { $0.id == id } ?? all.first { $0.keyword == keyword })?.id
    }

    private func groupIndex(_ place: SnippetPlacement) -> Int? {
        groups.firstIndex { $0.id == place.groupID } ?? groups.firstIndex { $0.name == place.groupName }
    }

    /// Puts `snippet` back at `place`, or last in a new group of that name if the group is gone. False if it's
    /// already here. A keyword taken meanwhile is the store's to refuse.
    @discardableResult
    mutating func restoreSnippet(_ snippet: Snippet, at place: SnippetPlacement) -> Bool {
        guard !groups.contains(where: { $0.snippets.contains { $0.id == snippet.id } }) else { return false }
        if let gi = groupIndex(place) {
            groups[gi].snippets.insert(snippet, at: min(place.index, groups[gi].snippets.count))
        } else {
            groups.append(SnippetGroup(name: place.groupName, snippets: [snippet]))
        }
        return true
    }

    mutating func restoreGroup(_ group: SnippetGroup, at index: Int) {
        groups.insert(group, at: min(index, groups.count))
    }

    /// Undoes a move: the snippet goes back to `place`. False, and no change, if it or that group is gone.
    @discardableResult
    mutating func moveSnippetBack(_ id: Snippet.ID, to place: SnippetPlacement) -> Bool {
        guard let gi = groupIndex(place),
              let from = groups.firstIndex(where: { $0.snippets.contains { $0.id == id } }),
              let fromIndex = groups[from].snippets.firstIndex(where: { $0.id == id }) else { return false }
        let snippet = groups[from].snippets.remove(at: fromIndex)
        groups[gi].snippets.insert(snippet, at: min(place.index, groups[gi].snippets.count))
        return true
    }
}
