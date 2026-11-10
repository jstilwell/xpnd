import Foundation
import Yams

enum SnippetYAMLError: Error, Equatable {
    case malformed(String)
    case unsupportedVersion(Int)
    case duplicateKeywords([String])
}

/// Shown as is: in the load-error banner and after a failed import.
extension SnippetYAMLError: CustomStringConvertible {
    var description: String {
        switch self {
        case .malformed(let detail): "This isn't a snippets file xpnd can read: \(detail)"
        case .unsupportedVersion(let version): "This file is version \(version), which this xpnd can't read."
        case .duplicateKeywords(let keywords): "These keywords are used more than once: \(keywords.joined(separator: ", "))"
        }
    }
}

enum SnippetYAML {
    static let currentVersion = 1

    private struct File: Codable {
        var version: Int?
        var groups: [Group]?
    }

    private struct Group: Codable {
        var name: String
        var description: String?
        var enabled: Bool?
        var snippets: [Item]?
    }

    private struct Item: Codable {
        var name: String
        var keyword: String
        var matching: MatchingMode?
        var enabled: Bool?
        var text: String
    }

    static func decode(_ yaml: String) throws(SnippetYAMLError) -> SnippetLibrary {
        let file: File
        do {
            // An empty document decodes to nil; treat it as an empty library.
            file = try YAMLDecoder().decode(File?.self, from: yaml) ?? File()
        } catch {
            throw .malformed(String(describing: error))
        }
        let version = file.version ?? currentVersion
        guard version == currentVersion else { throw .unsupportedVersion(version) }
        let library = SnippetLibrary(groups: (file.groups ?? []).map { g in
            SnippetGroup(name: g.name, description: g.description ?? "", enabled: g.enabled ?? true,
                         snippets: (g.snippets ?? []).map {
                Snippet(name: $0.name, keyword: $0.keyword, matching: $0.matching ?? .strict,
                        enabled: $0.enabled ?? true, text: $0.text)
            })
        })
        let dupes = library.duplicateKeywords
        guard dupes.isEmpty else { throw .duplicateKeywords(dupes) }
        return library
    }

    static func encode(_ library: SnippetLibrary) -> String {
        let file = File(version: currentVersion, groups: library.groups.map { g in
            Group(name: g.name, description: g.description, enabled: g.enabled, snippets: g.snippets.map {
                Item(name: $0.name, keyword: $0.keyword, matching: $0.matching, enabled: $0.enabled, text: $0.text)
            })
        })
        let encoder = YAMLEncoder()
        encoder.options.newLineScalarStyle = .literal
        // Plain strings/bools/enums can't fail to encode, so the fallback is unreachable.
        return (try? encoder.encode(file)) ?? ""
    }
}
