import Foundation

enum ConflictChoice: Sendable { case skip, replace }

struct RiskyAction: Hashable, Sendable {
    enum Kind: Sendable { case shell, openApp, runShortcut }
    let snippetName: String
    let keyword: String
    let kind: Kind
    let target: String
}

enum LibraryImport {
    /// Incoming keywords that already exist, sorted.
    static func conflicts(incoming: SnippetLibrary, existing: SnippetLibrary) -> [String] {
        let have = Set(existing.groups.flatMap(\.snippets).map(\.keyword))
        let clashing = Set(incoming.groups.flatMap(\.snippets).map(\.keyword)).intersection(have)
        return clashing.sorted()
    }

    /// Groups merge by exact name. `.replace` removes the existing snippet wherever it lives.
    static func merge(_ incoming: SnippetLibrary, into existing: SnippetLibrary, choice: ConflictChoice) -> SnippetLibrary {
        var result = existing
        for group in incoming.groups {
            var toAdd = group.snippets
            switch choice {
            case .skip:
                let have = Set(result.groups.flatMap(\.snippets).map(\.keyword))
                toAdd.removeAll { have.contains($0.keyword) }
            case .replace:
                let replaced = Set(toAdd.map(\.keyword))
                for gi in result.groups.indices {
                    result.groups[gi].snippets.removeAll { replaced.contains($0.keyword) }
                }
            }
            if let gi = result.groups.firstIndex(where: { $0.name == group.name }) {
                result.groups[gi].snippets += toAdd
            } else {
                var new = group
                new.snippets = toAdd
                result.groups.append(new)
            }
        }
        return result
    }

    static func riskyActions(in library: SnippetLibrary) -> [RiskyAction] {
        var found: [RiskyAction] = []
        for snippet in library.groups.flatMap(\.snippets) {
            for case let .variable(name, argument, _) in Template.parse(snippet.text) {
                guard let argument else { continue }
                let kind: RiskyAction.Kind
                var target = argument
                switch name {
                case "shell":
                    kind = .shell
                    // Drop a trailing ":<digits>" timeout.
                    if let r = target.range(of: #":\d+$"#, options: .regularExpression) { target.removeSubrange(r) }
                case "openApp": kind = .openApp
                case "runShortcut": kind = .runShortcut
                default: continue
                }
                found.append(RiskyAction(snippetName: snippet.name, keyword: snippet.keyword, kind: kind, target: target))
            }
        }
        return found
    }

    /// `groups == nil` exports every group.
    static func export(_ library: SnippetLibrary, groups: Set<SnippetGroup.ID>?) -> String {
        guard let groups else { return SnippetYAML.encode(library) }
        return SnippetYAML.encode(SnippetLibrary(groups: library.groups.filter { groups.contains($0.id) }))
    }
}
