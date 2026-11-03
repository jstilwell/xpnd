import Testing
@testable import xpnd

private func snippets(_ list: Snippet...) -> SnippetLibrary {
    SnippetLibrary(groups: [SnippetGroup(name: "Work", snippets: list)])
}

@Suite struct KeywordNamespaceTests {
    let signature = Snippet(name: "Signature", keyword: ";sig", text: "Jesse")
    let aws = Connection(name: "aws", host: "aws.example.com", activation: ";aws")
    var dev: ConnectionFolder { ConnectionFolder(id: Self.devID, name: "dev", connections: [aws]) }
    static let devID = ConnectionFolder.ID()

    @Test func derivedActivationEdgeCases() {
        #expect(ConnectionFolder.derivedActivation(for: "My Servers") == ";myservers")
        #expect(ConnectionFolder.derivedActivation(for: "Prod 🚀") == ";prod🚀")
        #expect(ConnectionFolder.derivedActivation(for: " \t") == "")

        // The same name in two branches: the first in tree order keeps the derived string.
        let devWeb = ConnectionFolder(name: "web"), prodWeb = ConnectionFolder(name: "web")
        let tree = ConnectionLibrary(folders: [
            ConnectionFolder(name: "dev", folders: [devWeb]),
            ConnectionFolder(name: "prod", folders: [prodWeb]),
        ])
        let namespace = KeywordNamespace(snippets: .empty, connections: tree)
        #expect(namespace.effectiveActivation(ofFolder: devWeb.id) == (";web", nil))
        #expect(namespace.effectiveActivation(ofFolder: prodWeb.id) == (nil, "“;web” is already used by folder “web”"))

        // Snippet keywords, connection strings and custom folder strings all beat a derived string.
        let devSnippet = Snippet(name: "Dev notes", keyword: ";dev", text: "x")
        let dev = ConnectionFolder(name: "dev")
        let withSnippet = KeywordNamespace(snippets: snippets(devSnippet), connections: ConnectionLibrary(folders: [dev]))
        #expect(withSnippet.effectiveActivation(ofFolder: dev.id) == (nil, "“;dev” is already used by “Dev notes”"))

        let prod = ConnectionFolder(name: "prod", connections: [Connection(name: "aws", host: "h", activation: ";prod")])
        let byConnection = KeywordNamespace(snippets: .empty, connections: ConnectionLibrary(folders: [prod]))
        #expect(byConnection.effectiveActivation(ofFolder: prod.id) == (nil, "“;prod” is already used by connection “aws”"))

        let later = ConnectionFolder(name: "web"), custom = ConnectionFolder(name: "site", activation: ";web")
        let byCustom = KeywordNamespace(snippets: .empty, connections: ConnectionLibrary(folders: [later, custom]))
        #expect(byCustom.effectiveActivation(ofFolder: later.id) == (nil, "“;web” is already used by folder “site”"))
        #expect(byCustom.effectiveActivation(ofFolder: custom.id) == (";web", nil))

        let none = ConnectionFolder(name: "quiet", activation: "")
        let withNone = KeywordNamespace(snippets: .empty, connections: ConnectionLibrary(folders: [none]))
        #expect(withNone.effectiveActivation(ofFolder: none.id) == (nil, nil))
    }

    @Test func problemMessages() {
        let namespace = KeywordNamespace(snippets: snippets(signature), connections: ConnectionLibrary(folders: [dev]))

        #expect(namespace.problem("", for: nil) == "Keyword can't be empty")
        #expect(namespace.problem(";a b", for: .folder(Self.devID)) == "Keywords can't contain spaces or tabs")
        #expect(namespace.problem(String(repeating: "a", count: 129), for: nil) == "Keywords can be at most 128 characters")

        #expect(namespace.problem(";dev", for: nil) == "“;dev” is already used by folder “dev”")
        #expect(namespace.problem(";aws", for: nil) == "“;aws” is already used by connection “aws”")
        #expect(namespace.problem(";sig", for: .folder(Self.devID)) == "“;sig” is already used by “Signature”")
        #expect(namespace.problem(";sig", for: .connection(aws.id)) == "“;sig” is already used by “Signature”")
        #expect(namespace.problem(";dev", for: .snippet(signature.id)) == "“;dev” is already used by folder “dev”")
        #expect(namespace.problem(";aws", for: .snippet(signature.id)) == "“;aws” is already used by connection “aws”")

        #expect(namespace.problem(";dev", for: .folder(Self.devID)) == nil)
        #expect(namespace.problem(";aws", for: .connection(aws.id)) == nil)
        #expect(namespace.problem(";sig", for: .snippet(signature.id)) == nil)
        #expect(namespace.problem(";new", for: nil) == nil)
    }

    @Test func crossFileDuplicatesTriggerNothing() {
        let x = Snippet(name: "X", keyword: ";x", text: "x")
        let folder = ConnectionFolder(name: "f", activation: "", connections: [
            Connection(name: "one", host: "h", activation: ";x"),
            Connection(name: "two", host: "h", activation: ";y"),
            Connection(name: "three", host: "h", activation: ";y"),
        ])
        let namespace = KeywordNamespace(snippets: snippets(x), connections: ConnectionLibrary(folders: [folder]))

        #expect(namespace.crossFileDuplicates == [";x"])
        #expect(namespace.activations[";x"] == nil)
        // A duplicate within connections.yaml triggers nothing either, but isn't cross-file.
        #expect(namespace.activations[";y"] == nil)
    }

    @Test func activationsMap() {
        let quiet = ConnectionFolder(name: "quiet", activation: "", connections: [Connection(name: "bare", host: "h")])
        let prod = ConnectionFolder(name: "prod", activation: ";p", folders: [quiet])
        let namespace = KeywordNamespace(snippets: snippets(signature), connections: ConnectionLibrary(folders: [dev, prod]))

        #expect(namespace.activations == [
            ";dev": .folder(Self.devID),
            ";aws": .connection(aws.id),
            ";p": .folder(prod.id),
        ])
        #expect(namespace.crossFileDuplicates.isEmpty)
    }
}
