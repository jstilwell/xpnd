import Foundation
import Testing
@testable import xpnd

@Suite struct SSHConfigImportTests {
    private func connections(_ text: String) -> [Connection] { SSHConfigImport.parse(text).library.allConnections }

    @Test func parsesAHostBlockIntoOneFolder() throws {
        let result = SSHConfigImport.parse("""
        # work
        Host web

          HostName 10.0.0.5
          User deploy
          Port 2222
        """)
        #expect(result.library.folders.map(\.name) == ["SSH config"])
        let c = try #require(result.library.allConnections.first)
        #expect(c.name == "web" && c.type == .ssh && c.host == "10.0.0.5" && c.username == "deploy" && c.port == 2222)
        #expect(result.notes.isEmpty)
    }

    @Test func theAliasIsTheHostWithoutAHostName() throws {
        #expect(try #require(connections("Host db.internal\n").first).host == "db.internal")
    }

    @Test func skipsWildcardHostsWithANote() {
        let result = SSHConfigImport.parse("Host *\n  User all\nHost *.example !x\nHost a b*\n  User me\n")
        #expect(result.library.allConnections.map(\.name) == ["a"])
        #expect(result.library.allConnections.first?.username == "me")
        #expect(result.notes == ["Skipped 2 Host entries that are patterns (*, ? or !)."])
    }

    @Test func firstValueWins() {
        #expect(connections("Host a\n  User one\n  User two\n").first?.username == "one")
    }

    @Test func equalsSignsQuotesAndCase() throws {
        let c = try #require(connections("host a\n  HostName=\"10.0.0.9\"\n  USER = me\n  port=22\n").first)
        #expect(c.host == "10.0.0.9" && c.username == "me" && c.port == 22)
    }

    @Test func ignoresIncludeAndMatchWithNotes() {
        let result = SSHConfigImport.parse("Include ~/.ssh/more\nHost a\nMatch host b\n  User x\nHost c\n")
        #expect(result.library.allConnections.map(\.name) == ["a", "c"])
        #expect(result.library.allConnections.allSatisfy { $0.username == nil })
        #expect(result.notes == ["Include lines were ignored.", "Match blocks were ignored."])
    }

    @Test func identityFileBecomesAQuotedOption() throws {
        let c = try #require(connections("Host a\n  IdentityFile \"~/.ssh/my key\"\n").first)
        #expect(try ShellQuote.split(c.sshOptions) == ["-i", "~/.ssh/my key"])
    }

    @Test func proxyJumpBecomesATextJumpHost() {
        let list = connections("Host a\n  ProxyJump bastion\nHost b\n  ProxyJump none\n")
        #expect(list.first?.jumpHost == .text("bastion"))
        #expect(list.last?.jumpHost == nil)
    }

    @Test func aBadPortIsDroppedWithANote() {
        let result = SSHConfigImport.parse("Host a\n  Port ssh\n")
        #expect(result.library.allConnections.first?.port == nil)
        #expect(result.notes == ["Skipped Port “ssh” for a: it isn't a port number."])
    }

    @Test func controlCharactersAreDropped() {
        let result = SSHConfigImport.parse("Host a\n  User me\u{1b}[2J\n")
        #expect(result.library.allConnections.first?.username == nil)
        #expect(result.notes == ["Skipped a User for a: it has a control character."])
    }

    @Test func nothingToImport() {
        #expect(SSHConfigImport.parse("# only comments\n").library.allConnections.isEmpty)
    }

    @Test func hostsAlreadyThereAreSkipped() {
        let existing = ConnectionLibrary(folders: [ConnectionFolder(name: "prod", connections: [Connection(name: "web", host: "10.0.0.5")])])
        let result = SSHConfigImport.parse("Host web\n  HostName 10.0.0.5\nHost db\n", existing: existing)
        #expect(result.library.allConnections.map(\.name) == ["db"])
        #expect(result.notes == ["Skipped 1 host already in your connections."])
    }
}
