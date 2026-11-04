import Foundation
import Testing
@testable import xpnd

private func stripIDs(_ lib: SnippetLibrary) -> SnippetLibrary {
    var l = lib
    for gi in l.groups.indices {
        l.groups[gi].id = .init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
        for si in l.groups[gi].snippets.indices {
            l.groups[gi].snippets[si].id = l.groups[gi].id
        }
    }
    return l
}

private let specExample = """
version: 1
groups:
  - name: Work
    description: Ticket boilerplate
    enabled: true
    snippets:
      - name: Ticket reply
        keyword: ";tix"
        matching: strict        # strict | loose
        enabled: true
        text: |
          Hi #{input:Name},
          Ticket #{input:Ticket #} is resolved as of #{dateTime:yyyy-MM-dd}.
          #{cursor}
"""

@Test func decodesSpecExample() throws {
    let lib = try SnippetYAML.decode(specExample)
    #expect(lib.groups.count == 1)
    #expect(lib.groups[0].name == "Work")
    let s = try #require(lib.groups[0].snippets.first)
    #expect(s.keyword == ";tix")
    #expect(s.matching == .strict)
    #expect(s.enabled)
    #expect(s.text.split(separator: "\n").count == 3)
}

@Test func missingOptionalFieldsDefault() throws {
    let lib = try SnippetYAML.decode("""
    version: 1
    groups:
      - name: G
        snippets:
          - {name: n, keyword: k, text: t}
    """)
    #expect(lib.groups[0].description == "")
    #expect(lib.groups[0].enabled)
    #expect(lib.groups[0].snippets[0].matching == .strict)
    #expect(lib.groups[0].snippets[0].enabled)
}

@Test func roundTripsThroughEncode() throws {
    let lib = SnippetLibrary(groups: [
        SnippetGroup(name: "A", description: "d", enabled: false, snippets: [
            Snippet(name: "x", keyword: "👍🏽", matching: .loose, enabled: false, text: "a\nb\n"),
            Snippet(name: "y", keyword: ";y", text: "plain"),
        ]),
        SnippetGroup(name: "B", snippets: []),
    ])
    let back = try SnippetYAML.decode(SnippetYAML.encode(lib))
    #expect(stripIDs(back) == stripIDs(lib))
}

@Test func multilineTextIsLiteralBlock() {
    let lib = SnippetLibrary(groups: [SnippetGroup(name: "G", snippets: [Snippet(name: "n", keyword: "k", text: "a\nb")])])
    #expect(SnippetYAML.encode(lib).contains("text: |"))
}

@Test func malformedYAMLThrows() {
    do {
        _ = try SnippetYAML.decode("groups: [")
        Issue.record("expected throw")
    } catch {
        guard case .malformed = error else { Issue.record("wrong error \(error)"); return }
    }
}

@Test func futureVersionThrows() {
    #expect(throws: SnippetYAMLError.unsupportedVersion(2)) { try SnippetYAML.decode("version: 2\ngroups: []") }
}

@Test func duplicateKeywordsThrow() {
    #expect(throws: SnippetYAMLError.duplicateKeywords([";a"])) {
        try SnippetYAML.decode("""
        groups:
          - {name: G1, snippets: [{name: a, keyword: ";a", text: t}]}
          - {name: G2, snippets: [{name: b, keyword: ";a", text: t}]}
        """)
    }
}

/// `bin/run.sh --test-snippets` installs this file; it must stay valid as the schema evolves.
@Test func manualTestSnippetsDecode() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Manual/test-snippets.yaml")
    let lib = try SnippetYAML.decode(String(contentsOf: url, encoding: .utf8))
    #expect(lib.activeSnippets.count == 10)
    #expect(lib.snippet(keyword: ";sig")?.text == "Best,\nJesse")
}

/// `bin/run.sh --test-snippets` also installs this file.
@Test func manualTestConnectionsDecode() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Manual/test-connections.yaml")
    let lib = try ConnectionYAML.decode(String(contentsOf: url, encoding: .utf8))
    #expect(lib.folders.map(\.name) == ["dev", "prod"])
    #expect(lib.allConnections.count == 5)
    let lo = try #require(lib.allConnections.first { $0.activation == ";lo" })
    #expect(lo.name == "localhost" && lo.effectivePort == 22 && lo.credential == nil)
    let vnc = try #require(lib.allConnections.first { $0.name == "vnc-mac" })
    #expect(vnc.type == .vnc && vnc.effectivePort == 5900)
    let bastion = try #require(lib.allConnections.first { $0.name == "bastion" })
    let web = try #require(lib.allConnections.first { $0.name == "web-01" })
    #expect(web.jumpHost == .connection(bastion.id))
    let text = try #require(lib.allConnections.first { $0.name == "jump-text" })
    #expect(text.jumpHost == .text("jump.example.com") && text.sshOptions == "-o ServerAliveInterval=30" && text.autoSudo)
    #expect(lib.allConnections.allSatisfy { $0.credential == nil && $0.sudoCredential == nil })
}
