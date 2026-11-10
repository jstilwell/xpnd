import Foundation

enum ActivationTarget: Hashable, Sendable {
    case connection(Connection.ID), folder(ConnectionFolder.ID)
}

/// Snippet keywords and connection/folder activation strings share one namespace.
struct KeywordNamespace {
    enum Owner: Hashable {
        case snippet(Snippet.ID), folder(ConnectionFolder.ID), connection(Connection.ID)
    }

    let snippets: SnippetLibrary
    let connections: ConnectionLibrary
    /// The trees flattened once: the sidebar asks about every folder on each pass, and each answer walks them all.
    private let allSnippets: [Snippet]
    private let allConnections: [Connection]
    private let allFolders: [ConnectionFolder]

    init(snippets: SnippetLibrary, connections: ConnectionLibrary) {
        self.snippets = snippets
        self.connections = connections
        allSnippets = snippets.groups.flatMap(\.snippets)
        allConnections = connections.allConnections
        allFolders = connections.allFolders
    }

    /// Why `string` can't be used by `owner` (nil for a new item), or nil if it can.
    func problem(_ string: String, for owner: Owner?) -> String? {
        var snippetID: Snippet.ID?
        if case .snippet(let id) = owner { snippetID = id }
        // The format rules and the snippet owner's message stay exactly as `keywordProblem` has them.
        if let problem = snippets.keywordProblem(string, for: snippetID) { return problem }
        if let other = allConnections.first(where: { $0.activation == string && owner != .connection($0.id) }) {
            return "“\(string)” is already used by connection “\(other.name)”"
        }
        if let other = allFolders.first(where: {
            owner != .folder($0.id) && effectiveActivation(ofFolder: $0.id).string == string
        }) {
            return "“\(string)” is already used by folder “\(other.name)”"
        }
        return nil
    }

    /// A custom string always stands (duplicates are flagged, not dropped). A derived one yields to
    /// snippet keywords, connection strings and custom folder strings (and any of those it's a prefix
    /// of), and earlier folders in tree order.
    func effectiveActivation(ofFolder id: ConnectionFolder.ID) -> (string: String?, reason: String?) {
        guard let folder = allFolders.first(where: { $0.id == id }) else { return (nil, nil) }
        if let custom = folder.activation { return (custom.isEmpty ? nil : custom, nil) }
        let derived = ConnectionFolder.derivedActivation(for: folder.name)
        if derived.isEmpty { return (nil, nil) }
        let taken = "“\(derived)” is already used by"
        if let snippet = allSnippets.first(where: { $0.keyword == derived }) { return (nil, "\(taken) “\(snippet.name)”") }
        // Typing the derived string would fire it before a longer snippet keyword could finish.
        if let longer = allSnippets.first(where: { $0.keyword != derived && $0.keyword.hasPrefix(derived) }) {
            return (nil, "“\(derived)” would hide the snippet “\(longer.keyword)”")
        }
        func longer(_ string: String?) -> String? { string.flatMap { $0 != derived && $0.hasPrefix(derived) ? $0 : nil } }
        for other in allConnections {
            if let string = longer(other.activation) { return (nil, "“\(derived)” would hide “\(string)”, used by connection “\(other.name)”") }
        }
        for other in allFolders {
            if let string = longer(other.activation) { return (nil, "“\(derived)” would hide “\(string)”, used by folder “\(other.name)”") }
        }
        if let other = allConnections.first(where: { $0.activation == derived }) {
            return (nil, "\(taken) connection “\(other.name)”")
        }
        let folders = allFolders
        if let other = folders.first(where: { $0.activation == derived })
            ?? folders.first(where: { $0.activation == nil && ConnectionFolder.derivedActivation(for: $0.name) == derived }),
           other.id != id {
            return (nil, "\(taken) folder “\(other.name)”")
        }
        return (derived, nil)
    }

    /// Every string with exactly one owner across both files.
    var activations: [String: ActivationTarget] {
        let keywords = snippetKeywords
        let byString = Dictionary(grouping: entries, by: \.string)
        return byString.compactMapValues { owners in owners.count == 1 ? owners[0].target : nil }
            .filter { !keywords.contains($0.key) }
    }

    /// Strings owned in both files, which trigger nothing until resolved.
    var crossFileDuplicates: Set<String> {
        Set(entries.map(\.string)).intersection(snippetKeywords)
    }

    private var snippetKeywords: Set<String> { Set(allSnippets.map(\.keyword)) }

    private var entries: [(string: String, target: ActivationTarget)] {
        allConnections.compactMap { connection in
            connection.activation.flatMap { $0.isEmpty ? nil : ($0, .connection(connection.id)) }
        } + allFolders.compactMap { folder in
            effectiveActivation(ofFolder: folder.id).string.map { ($0, .folder(folder.id)) }
        }
    }
}
