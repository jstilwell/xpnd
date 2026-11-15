import Foundation

enum ConflictChoice: Sendable { case skip, replace }

struct RiskyAction: Hashable, Sendable {
    enum Kind: Sendable { case shell, openApp, runShortcut, shortcut, key }
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

    /// `library` without the snippets whose keyword is in `reserved` (strings the connections file uses: a keyword
    /// owned in both files triggers neither), and those keywords, sorted.
    static func removing(_ reserved: Set<String>, from library: SnippetLibrary) -> (SnippetLibrary, [String]) {
        var library = library
        var removed: Set<String> = []
        for gi in library.groups.indices {
            library.groups[gi].snippets.removeAll { snippet in
                guard reserved.contains(snippet.keyword) else { return false }
                removed.insert(snippet.keyword)
                return true
            }
        }
        return (library, removed.sorted())
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
                // Keys sent to whatever is in front can open Terminal and type a command.
                case "shortcut": kind = .shortcut
                // Typed text plus Return is a command run in whatever terminal the keyword is typed in.
                case "key": kind = .key
                default: continue
                }
                found.append(RiskyAction(snippetName: snippet.name, keyword: snippet.keyword, kind: kind, target: target))
            }
            // Typed as keystrokes (remote desktops, or everywhere by the setting), a new line is a press of Return.
            if snippet.text.contains(where: \.isNewline) {
                found.append(RiskyAction(snippetName: snippet.name, keyword: snippet.keyword, kind: .key, target: "Return (a new line in its text)"))
            }
        }
        return found
    }

    /// What merging with `choice` did, for the message after an import; nil when it would add nothing,
    /// so the caller can leave the file alone.
    static func outcome(incoming: SnippetLibrary, existing: SnippetLibrary, choice: ConflictChoice) -> String? {
        let skipped = choice == .skip ? conflicts(incoming: incoming, existing: existing).count : 0
        let added = incoming.groups.flatMap(\.snippets).count - skipped
        guard added > 0 else { return nil }
        let imported = "Imported \(added) snippet\(added == 1 ? "" : "s")"
        let summary = skipped == 0 ? imported + "." : imported + "; skipped \(skipped) that already exist\(skipped == 1 ? "s" : "")."
        // Groups merge by name, so snippets can land in one that's off and never expand.
        let off = incoming.groups.filter { !$0.snippets.isEmpty }.compactMap { group in
            existing.groups.first { $0.name == group.name && !$0.enabled }.map { "“\($0.name)”" }
        }
        guard !off.isEmpty else { return summary }
        let one = off.count == 1
        return summary + " \(one ? "The group" : "The groups") \(off.joined(separator: ", ")) \(one ? "is" : "are") turned off, so turn \(one ? "it" : "them") on to use them."
    }

    /// `groups == nil` exports every group.
    static func export(_ library: SnippetLibrary, groups: Set<SnippetGroup.ID>?) -> String {
        guard let groups else { return SnippetYAML.encode(library) }
        return SnippetYAML.encode(SnippetLibrary(groups: library.groups.filter { groups.contains($0.id) }))
    }
}
