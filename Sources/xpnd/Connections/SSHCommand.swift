import Foundation

enum SSHCommandError: Error, Equatable {
    case unbalancedQuote, jumpHostMissing, jumpHostCycle, jumpHostChainTooLong, jumpHostNeedsKey(String), notSSH, controlCharacter(String)
    case emptyHost(String)

    var message: String {
        switch self {
        case .unbalancedQuote: "The extra SSH options have an unmatched quote."
        case .jumpHostMissing: "The jump host points to a connection that no longer exists."
        case .jumpHostCycle: "The jump hosts form a loop."
        case .jumpHostChainTooLong: "Jump-host chains can be at most \(SSHCommandBuilder.maxJumpHops) hops."
        case .jumpHostNeedsKey(let name): "The jump host “\(name)” must be an SSH connection that uses an SSH key."
        case .notSSH: "This isn't an SSH connection."
        case .emptyHost(let name): "“\(name)” has no host."
        case .controlCharacter(let name): "“\(name)” has a control character in its settings, so xpnd won't type it."
        }
    }
}

struct SSHCommand: Equatable, Sendable {
    let arguments: [String]

    var shellLine: String { arguments.map(ShellQuote.quote).joined(separator: " ") }
}

enum SSHCommandBuilder {
    static let agentSocket = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
    /// Each hop roughly quadruples the quoting, so a long hand-edited chain would hang the main thread.
    static let maxJumpHops = 5

    static func keyFile(_ ref: CredentialRef, in keysDirectory: URL) -> URL {
        keysDirectory.appendingPathComponent("\(ref.item).pub")
    }

    /// Public keys aren't secret, so 0644 like `~/.ssh/*.pub`. The caller checks `ref.item` is safe.
    static func writeKeyFile(_ key: String, for ref: CredentialRef, in keysDirectory: URL) throws {
        let file = keyFile(ref, in: keysDirectory)
        try FileManager.default.createDirectory(at: keysDirectory, withIntermediateDirectories: true)
        try Data(key.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }

    /// A connection that no longer exists also throws `.notSSH`: the error set has no closer case.
    static func build(_ id: Connection.ID, in library: ConnectionLibrary, keysDirectory: URL) throws(SSHCommandError) -> SSHCommand {
        guard let connection = library.connection(id), connection.type == .ssh else { throw .notSSH }
        // ssh would otherwise report "Could not resolve hostname :", which doesn't name the connection.
        guard !connection.host.trimmingCharacters(in: .whitespaces).isEmpty else { throw .emptyHost(connection.name) }
        var arguments = ["ssh"]
        arguments += try options(for: connection, visited: [id], library, keysDirectory)
        if connection.autoSudo { arguments.append("-t") }
        arguments += target(of: connection, library)
        if connection.autoSudo { arguments += ["sudo", "-i"] }
        // Quoting can't hold these once pasted: Ctrl-U erases the opening quote and \r runs the rest.
        // Jump hosts' values sit inside the ProxyCommand argument, so this covers them too.
        guard !arguments.joined().unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw .controlCharacter(connection.name)
        }
        return SSHCommand(arguments: arguments)
    }

    /// Everything between `ssh` and the target, except `-t`. `visited` is the jump chain so far.
    private static func options(
        for connection: Connection, visited: Set<Connection.ID>, _ library: ConnectionLibrary, _ keysDirectory: URL
    ) throws(SSHCommandError) -> [String] {
        var arguments: [String] = []
        if connection.effectivePort != ConnectionType.ssh.defaultPort { arguments += ["-p", String(connection.effectivePort)] }
        switch connection.jumpHost {
        case .text(let text): arguments += ["-J", text]
        case .connection(let id): arguments += ["-o", "ProxyCommand=" + (try proxyCommand(id, visited: visited, library, keysDirectory))]
        case nil: break
        }
        if let ref = library.loginCredential(for: connection.id)?.ref {
            if ref.category == .sshKey {
                // ssh splits -o values on spaces, so the socket needs its own quotes inside the argument.
                arguments += ["-o", "IdentityAgent=\"\(agentSocket)\"", "-o", "IdentitiesOnly=yes",
                              "-i", keyFile(ref, in: keysDirectory).path]
            } else {
                arguments += ["-o", "PubkeyAuthentication=no"]
            }
        }
        return arguments + (try ShellQuote.split(connection.sshOptions))
    }

    /// `--` keeps a value starting with `-` from being read as an ssh option.
    private static func target(of connection: Connection, _ library: ConnectionLibrary) -> [String] {
        let destination = library.loginUser(for: connection).map { "\($0)@\(connection.host)" } ?? connection.host
        return destination.hasPrefix("-") ? ["--", destination] : [destination]
    }

    /// A shell command string: ssh runs ProxyCommand through the user's shell.
    private static func proxyCommand(
        _ id: Connection.ID, visited: Set<Connection.ID>, _ library: ConnectionLibrary, _ keysDirectory: URL
    ) throws(SSHCommandError) -> String {
        guard !visited.contains(id) else { throw .jumpHostCycle }
        guard visited.count <= maxJumpHops else { throw .jumpHostChainTooLong }
        guard let jump = library.connection(id) else { throw .jumpHostMissing }
        guard jump.type == .ssh, library.loginCredential(for: id)?.ref.category == .sshKey else { throw .jumpHostNeedsKey(jump.name) }
        let before = try options(for: jump, visited: visited.union([id]), library, keysDirectory)
        // ssh expands % tokens in ProxyCommand once, so only -W's own tokens stay live.
        func literal(_ arguments: [String]) -> [String] {
            arguments.map { ShellQuote.quote($0.replacingOccurrences(of: "%", with: "%%", options: .literal)) }
        }
        // Brackets for IPv6 targets; quoted because zsh would glob a bare `[`.
        return (["ssh"] + literal(before) + ["-W", "'[%h]:%p'"] + literal(target(of: jump, library))).joined(separator: " ")
    }
}
