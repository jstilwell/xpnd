import Foundation
import Testing
@testable import xpnd

private let keys = URL(fileURLWithPath: "/Users/me/Library/Application Support/xpnd/keys")

private func ref(_ item: String, _ category: CredentialCategory, username: String? = nil) -> CredentialRef {
    CredentialRef(account: "acct", vault: "vault", item: item, title: item, category: category, username: username)
}

private func library(_ connections: [Connection]) -> ConnectionLibrary {
    ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: connections)])
}

private func build(_ connection: Connection, with others: Connection...) throws(SSHCommandError) -> SSHCommand {
    try SSHCommandBuilder.build(connection.id, in: library([connection] + others), keysDirectory: keys)
}

private func keyOptions(_ item: String) -> [String] {
    ["-o", "IdentityAgent=\"\(SSHCommandBuilder.agentSocket)\"", "-o", "IdentitiesOnly=yes", "-i", keys.path + "/\(item).pub"]
}

/// The value of `-o ProxyCommand=…`.
private func proxyCommand(_ command: SSHCommand) throws -> String {
    let value = try #require(command.arguments.first { $0.hasPrefix("ProxyCommand=") })
    return String(value.dropFirst("ProxyCommand=".count))
}

/// Harmless on purpose: these run through real shells, so a quoting bug must not do damage.
private let hostileValues = [
    "a;echo pwned", "$(echo pwned)", "`echo pwned`", "$HOME", "*", "~", "a b", "it's", "'", "''", "\"", "\\",
    "x\\'", "\\'", "a\\", "'\u{301};echo pwned;'", "a&echo pwned", "a|echo pwned", "a>pwned", "#a", "!a", "{a,b}", "é", "",
]

private let controlValues = ["a\nb", "a\tb", "x\u{15}touch M\r", "\r", "\u{1b}[201~", "\u{7f}", "\u{85}", "\u{9f}"]

@Suite struct SSHCommandTests {
    @Test func plainConnection() throws {
        #expect(try build(Connection(name: "a", host: "54.242.245.93")).arguments == ["ssh", "54.242.245.93"])
    }

    @Test func portAndUser() throws {
        var c = Connection(name: "a", host: "host", port: 2222, username: "ubuntu", credential: ref("k", .login, username: "cred"))
        #expect(try build(c).arguments == ["ssh", "-p", "2222", "-o", "PubkeyAuthentication=no", "ubuntu@host"])
        c.username = nil
        #expect(try build(c).arguments.last == "cred@host")
        c.username = ""
        #expect(try build(c).arguments.last == "cred@host")
    }

    @Test func sshKeyCredential() throws {
        let c = Connection(name: "a", host: "host", credential: ref("item1", .sshKey))
        #expect(try build(c).arguments == ["ssh"] + keyOptions("item1") + ["host"])
    }

    @Test func inheritedCredentialIsUsed() throws {
        let c = Connection(name: "a", host: "host")
        let folder = ConnectionFolder(name: "f", credential: ref("item1", .sshKey, username: "deploy"), connections: [c])
        let command = try SSHCommandBuilder.build(c.id, in: ConnectionLibrary(folders: [folder]), keysDirectory: keys)
        #expect(command.arguments == ["ssh"] + keyOptions("item1") + ["deploy@host"])
    }

    @Test(arguments: [CredentialCategory.login, .password, .server])
    func passwordCredential(category: CredentialCategory) throws {
        let c = Connection(name: "a", host: "host", credential: ref("p", category))
        #expect(try build(c).arguments == ["ssh", "-o", "PubkeyAuthentication=no", "host"])
    }

    @Test func extraOptionsSplit() throws {
        var c = Connection(name: "a", host: "host", sshOptions: #"-o "ProxyJump=none" -v"#)
        #expect(try build(c).arguments == ["ssh", "-o", "ProxyJump=none", "-v", "host"])
        c.sshOptions = #"-o "unterminated"#
        #expect(throws: SSHCommandError.unbalancedQuote) { try build(c) }
    }

    @Test func autoSudo() throws {
        let c = Connection(name: "a", host: "host", username: "u", sshOptions: "-v", autoSudo: true)
        #expect(try build(c).arguments == ["ssh", "-v", "-t", "u@host", "sudo", "-i"])
    }

    @Test func argumentOrder() throws {
        let c = Connection(name: "a", host: "host", port: 2200, username: "u", credential: ref("k", .sshKey),
                           jumpHost: .text("j"), sshOptions: "-v", autoSudo: true)
        #expect(try build(c).arguments == ["ssh", "-p", "2200", "-J", "j"] + keyOptions("k") + ["-v", "-t", "u@host", "sudo", "-i"])
    }

    @Test func jumpText() throws {
        let c = Connection(name: "a", host: "host", jumpHost: .text("ec2-user@bastion:22"))
        #expect(try build(c).arguments == ["ssh", "-J", "ec2-user@bastion:22", "host"])
    }

    @Test func jumpSavedConnection() throws {
        let jump = Connection(name: "bastion", host: "jump", port: 2022, username: "user",
                              credential: ref("jk", .sshKey), sshOptions: "-v")
        let c = Connection(name: "a", host: "host", credential: ref("k", .sshKey), jumpHost: .connection(jump.id))
        let command = try build(c, with: jump)
        let value = try proxyCommand(command)

        #expect(command.arguments.prefix(2) == ["ssh", "-o"])
        #expect(command.arguments[2] == "ProxyCommand=" + value)
        #expect(Array(command.arguments[3...]) == keyOptions("k") + ["host"])
        #expect(value.contains(" -W '[%h]:%p' "))
        #expect(try ShellQuote.split(value) == ["ssh", "-p", "2022"] + keyOptions("jk") + ["-v", "-W", "[%h]:%p", "user@jump"])
        #expect(try ShellQuote.split(command.shellLine) == command.arguments)
    }

    @Test func jumpChainEscapesInnerTokens() throws {
        let far = Connection(name: "far", host: "far", credential: ref("fk", .sshKey))
        let near = Connection(name: "near", host: "near", credential: ref("nk", .sshKey), jumpHost: .connection(far.id))
        let c = Connection(name: "a", host: "host", jumpHost: .connection(near.id))
        let outer = try ShellQuote.split(try proxyCommand(try build(c, with: near, far)))

        // ssh expands the outer value once, so the inner %h must reach the inner ssh intact.
        let inner = try ShellQuote.split(String(outer[2].dropFirst("ProxyCommand=".count)))
        #expect(outer.prefix(2) == ["ssh", "-o"])
        #expect(outer.suffix(3) == ["-W", "[%h]:%p", "near"])
        #expect(inner == ["ssh"] + keyOptions("fk") + ["-W", "[%%h]:%%p", "far"])
    }

    @Test func jumpLiteralPercentIsEscaped() throws {
        let jump = Connection(name: "j", host: "jump", username: "a%hb", credential: ref("k", .sshKey), sshOptions: "-o Tag=%p")
        let c = Connection(name: "a", host: "host", jumpHost: .connection(jump.id))
        let parts = try ShellQuote.split(try proxyCommand(try build(c, with: jump)))
        #expect(parts.suffix(4) == ["Tag=%%p", "-W", "[%h]:%p", "a%%hb@jump"])
    }

    @Test func jumpCycleAndMissing() {
        let key = ref("k", .sshKey)
        var a = Connection(name: "a", host: "a", credential: key)
        var b = Connection(name: "b", host: "b", credential: key)
        let c = Connection(name: "c", host: "c", credential: key, jumpHost: .connection(a.id))
        a.jumpHost = .connection(b.id)
        b.jumpHost = .connection(a.id)
        #expect(throws: SSHCommandError.jumpHostCycle) { try build(a, with: b) }
        #expect(throws: SSHCommandError.jumpHostCycle) { try build(c, with: a, b) }

        var selfJump = Connection(name: "s", host: "s", credential: key)
        selfJump.jumpHost = .connection(selfJump.id)
        #expect(throws: SSHCommandError.jumpHostCycle) { try build(selfJump) }

        let orphan = Connection(name: "o", host: "o", credential: key, jumpHost: .connection(UUID()))
        #expect(throws: SSHCommandError.jumpHostMissing) { try build(orphan) }
        let deep = Connection(name: "d", host: "d", credential: key, jumpHost: .connection(orphan.id))
        #expect(throws: SSHCommandError.jumpHostMissing) { try build(deep, with: orphan) }
    }

    /// Quoting grows about fourfold per hop, so a long hand-edited chain would hang the builder.
    @Test func jumpChainIsCappedAtFiveHops() throws {
        func chain(_ hops: Int) -> (Connection, [Connection]) {
            var jumps = [Connection(name: "j0", host: "j0", credential: ref("k", .sshKey))]
            for i in 1..<hops {
                jumps.append(Connection(name: "j\(i)", host: "j\(i)", credential: ref("k", .sshKey), jumpHost: .connection(jumps[i - 1].id)))
            }
            return (Connection(name: "a", host: "host", jumpHost: .connection(jumps[hops - 1].id)), jumps)
        }
        let (five, fiveJumps) = chain(5)
        #expect(try SSHCommandBuilder.build(five.id, in: library([five] + fiveJumps), keysDirectory: keys).arguments.last == "host")
        let (six, sixJumps) = chain(6)
        #expect(throws: SSHCommandError.jumpHostChainTooLong) {
            try SSHCommandBuilder.build(six.id, in: library([six] + sixJumps), keysDirectory: keys)
        }
    }

    @Test func jumpPasswordRefused() throws {
        var bastion = Connection(name: "bastion", host: "b", credential: ref("p", .login))
        var c = Connection(name: "a", host: "host", jumpHost: .connection(bastion.id))
        #expect(throws: SSHCommandError.jumpHostNeedsKey("bastion")) { try build(c, with: bastion) }
        bastion.credential = nil
        #expect(throws: SSHCommandError.jumpHostNeedsKey("bastion")) { try build(c, with: bastion) }
        bastion.credential = ref("k", .sshKey)
        bastion.type = .vnc
        #expect(throws: SSHCommandError.jumpHostNeedsKey("bastion")) { try build(c, with: bastion) }
        c.jumpHost = nil
        #expect(try build(c, with: bastion).arguments == ["ssh", "host"])
    }

    @Test func notSSH() {
        let c = Connection(name: "a", type: .vnc, host: "host")
        #expect(throws: SSHCommandError.notSSH) { try build(c) }
        #expect(throws: SSHCommandError.notSSH) {
            try SSHCommandBuilder.build(UUID(), in: library([c]), keysDirectory: keys)
        }
    }

    @Test func messages() {
        let errors: [SSHCommandError] = [.unbalancedQuote, .jumpHostMissing, .jumpHostCycle, .jumpHostNeedsKey("bastion"), .notSSH, .controlCharacter("aws"),
                                       .jumpHostChainTooLong]
        #expect(errors.allSatisfy { !$0.message.isEmpty && !$0.message.contains("\n") })
        #expect(SSHCommandError.jumpHostNeedsKey("bastion").message.contains("“bastion”"))
        #expect(SSHCommandError.controlCharacter("aws").message.contains("“aws”"))
    }

    @Test func hostileValuesAreQuoted() throws {
        let c = Connection(name: "a", host: "a;rm -rf ~", username: "$(id)", sshOptions: "'x y'")
        let command = try build(c)
        #expect(command.arguments == ["ssh", "x y", "$(id)@a;rm -rf ~"])
        #expect(command.shellLine == "ssh 'x y' '$(id)@a;rm -rf ~'")
        #expect(try ShellQuote.split(command.shellLine) == command.arguments)

        for value in hostileValues {
            let option = ShellQuote.quote(value)
            let c = Connection(name: "a", host: value, port: 2222, username: value, credential: ref(value, .sshKey),
                               jumpHost: .text(value), sshOptions: "-o \(option)", autoSudo: true)
            let command = try build(c)
            #expect(command.arguments.contains(value))
            #expect(try ShellQuote.split(command.shellLine) == command.arguments)
            #expect(try ShellQuote.split(build(Connection(name: "a", host: value)).shellLine) == ["ssh", value])
        }
        #expect(throws: SSHCommandError.controlCharacter("a")) { try build(Connection(name: "a", host: "a\nb")) }
        // Not in controlValues: URL turns a NUL in the key item into a harmless literal %00.
        #expect(throws: SSHCommandError.controlCharacter("a")) { try build(Connection(name: "a", host: "a\u{0}b")) }
    }

    /// Quoted is not enough: a pasted Ctrl-U or \r acts before the shell ever sees the quotes.
    @Test(arguments: controlValues)
    func controlCharactersAreRefused(value: String) {
        let quoted = "-o \(ShellQuote.quote(value))"
        let refused = SSHCommandError.controlCharacter("a")
        let key = ref("k", .sshKey)

        let direct = [
            Connection(name: "a", host: value),
            Connection(name: "a", host: "h", username: value),
            Connection(name: "a", host: "h", credential: ref("k", .login, username: value)),
            Connection(name: "a", host: "h", credential: ref(value, .sshKey)),
            Connection(name: "a", host: "h", jumpHost: .text(value)),
            Connection(name: "a", host: "h", sshOptions: quoted),
        ]
        for c in direct { #expect(throws: refused) { try build(c) } }

        let hops = [
            Connection(name: "j", host: value, credential: key),
            Connection(name: "j", host: "j", username: value, credential: key),
            Connection(name: "j", host: "j", credential: ref(value, .sshKey)),
            Connection(name: "j", host: "j", credential: key, jumpHost: .text(value)),
            Connection(name: "j", host: "j", credential: key, sshOptions: quoted),
        ]
        for jump in hops {
            let c = Connection(name: "a", host: "h", jumpHost: .connection(jump.id))
            #expect(throws: refused) { try build(c, with: jump) }
            let near = Connection(name: "near", host: "near", credential: key, jumpHost: .connection(jump.id))
            let far = Connection(name: "a", host: "h", jumpHost: .connection(near.id))
            #expect(throws: refused) { try build(far, with: near, jump) }
        }
    }

    @Test func hostileJumpValuesAreQuotedTwice() throws {
        for value in hostileValues where !value.isEmpty {
            let jump = Connection(name: "j", host: value, username: value, credential: ref("k", .sshKey), sshOptions: "-o \(ShellQuote.quote(value))")
            let c = Connection(name: "a", host: "host", jumpHost: .connection(jump.id))
            let command = try build(c, with: jump)
            let parts = try ShellQuote.split(try proxyCommand(command))
            #expect(try ShellQuote.split(command.shellLine) == command.arguments)
            #expect(parts.suffix(4) == [value, "-W", "[%h]:%p", "\(value)@\(value)"])
        }
    }

    /// `-oProxyCommand=…` as a bare argument would be read by ssh as an option and run.
    @Test func targetCannotBecomeAnOption() throws {
        let host = Connection(name: "a", host: "-oProxyCommand=echo", autoSudo: true)
        #expect(try build(host).arguments == ["ssh", "-t", "--", "-oProxyCommand=echo", "sudo", "-i"])

        let user = Connection(name: "a", host: "h", username: "-oProxyCommand=echo")
        #expect(try build(user).arguments == ["ssh", "--", "-oProxyCommand=echo@h"])

        let jump = Connection(name: "j", host: "-oProxyCommand=echo", credential: ref("k", .sshKey))
        let c = Connection(name: "a", host: "host", jumpHost: .connection(jump.id))
        let parts = try ShellQuote.split(try proxyCommand(try build(c, with: jump)))
        #expect(parts.suffix(4) == ["-W", "[%h]:%p", "--", "-oProxyCommand=echo"])
    }

    @Test func quoteForms() {
        #expect(ShellQuote.quote("Ab0_@%+=:,./-") == "Ab0_@%+=:,./-")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("a b") == "'a b'")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.quote(#"a\b"#) == #"'a'\\'b'"#)
        #expect(ShellQuote.quote(#"\'"#) == #"''\\''\'''"#)
        #expect(ShellQuote.quote("~") == "'~'")
        #expect(ShellQuote.quote("é") == "'é'")
        // The quote and the combining mark are one Character; a Character-level replace would miss it.
        #expect(ShellQuote.quote("'\u{301}") == "''\\''\u{301}'")
    }

    /// fish and ssh's `-o` parser read `\` inside single quotes; POSIX shells don't. Outside
    /// quotes they all agree, which is what keeps the quoting safe in each.
    @Test func noBackslashInsideSingleQuotes() {
        for value in hostileValues {
            var inside = false
            var scalars = ShellQuote.quote(value).unicodeScalars.makeIterator()
            while let c = scalars.next() {
                if c == "'" { inside.toggle() }
                if c == "\\" {
                    #expect(!inside)
                    _ = scalars.next()
                }
            }
            #expect(!inside)
        }
    }

    @Test func splitForms() throws {
        #expect(try ShellQuote.split("") == [])
        #expect(try ShellQuote.split(" \t\n ") == [])
        #expect(try ShellQuote.split(" a  b\tc\nd ") == ["a", "b", "c", "d"])
        #expect(try ShellQuote.split("''") == [""])
        #expect(try ShellQuote.split(#"a'' "" "#) == ["a", ""])
        #expect(try ShellQuote.split(#"'a "b" \n'"#) == [#"a "b" \n"#])
        #expect(try ShellQuote.split(#""a \" \\ \$ \` \n 'b'""#) == [#"a " \ $ ` \n 'b'"#])
        #expect(try ShellQuote.split(#"a\ b \'c\\"#) == ["a b", "'c\\"])
        #expect(try ShellQuote.split(#"a"b c"'d e'f"#) == ["ab cd ef"])
        #expect(try ShellQuote.split("$HOME $(id) `id` ~ *") == ["$HOME", "$(id)", "`id`", "~", "*"])
    }

    @Test(arguments: ["'", "\"", "a'b", #"a"b"#, "\\", #"a\"#, #""\"#, #"'\''"#])
    func splitRefusesUnbalanced(input: String) {
        #expect(throws: SSHCommandError.unbalancedQuote) { try ShellQuote.split(input) }
    }

    /// `split` and `quote` could share a bug, so a real shell has the last word.
    /// A shell function stands in for ssh and prints its argv.
    @Test(arguments: ["/bin/sh", "/bin/bash", "/bin/zsh"])
    func shellLineSurvivesRealShells(shell: String) async throws {
        for value in hostileValues {
            let c = Connection(name: "a", host: value, username: value, sshOptions: "-o \(ShellQuote.quote(value))")
            let command = try build(c)
            let script = #"ssh() { printf '%s\0' ssh "$@"; }; "# + command.shellLine
            let result = try await ProcessRunner.run(URL(fileURLWithPath: shell), arguments: ["-c", script], timeoutMs: 10_000)
            #expect(result.status == 0)
            #expect(result.stdout.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init) == command.arguments)
        }
    }

    /// Catches what string checks can't: ssh re-parses `-o` values with its own quoting rules.
    /// Walks a four-hop chain the way ssh would, checking every level's command with `ssh -G`.
    @Test func realSSHAcceptsEveryHop() async throws {
        var hops = [Connection(name: "h0", host: "h0", credential: ref("k0", .sshKey), sshOptions: "-o " + ShellQuote.quote(#"Tag="it\'s""#))]
        for i in 1...3 {
            hops.append(Connection(name: "h\(i)", host: "h\(i)", credential: ref("k\(i)", .sshKey), jumpHost: .connection(hops[i - 1].id)))
        }
        let c = Connection(name: "a", host: "host", port: 2222, credential: ref("k", .sshKey), jumpHost: .connection(hops[3].id))
        var arguments = Array(try SSHCommandBuilder.build(c.id, in: library([c] + hops), keysDirectory: keys).arguments.dropFirst())

        var levels = 0
        while true {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ssh"), arguments: ["-F", "/dev/null", "-G"] + arguments, timeoutMs: 10_000)
            #expect(result.status == 0)
            #expect(result.stdout.contains("Group Containers/2BUA8C4S2C.com.1password/t/agent.sock\n"))
            levels += 1
            guard let proxy = arguments.first(where: { $0.hasPrefix("ProxyCommand=") }) else { break }
            // What ssh hands to the shell, then what the shell hands to the next ssh.
            arguments = try ShellQuote.split(String(proxy.dropFirst("ProxyCommand=".count))).dropFirst().map {
                $0 == "[%h]:%p" ? "[::1]:22" : $0.replacingOccurrences(of: "%%", with: "%")
            }
        }
        #expect(levels == 5)
        #expect(arguments.contains(#"Tag="it\'s""#))
    }
}
