import Foundation

@MainActor protocol PasswordPrompting {
    /// True if the user wants the sudo password copied now.
    func offerSudo(for name: String) async -> Bool
}

/// Turns a connection into action: resolve, build, launch or type, then copy any passwords. The
/// command goes out before any password is fetched, so a Touch ID prompt can't land between the
/// front-app check and the typing. Never log or show a secret or the command.
@MainActor final class ConnectionService {
    private let connections: ConnectionStore
    private let provider: any CredentialProvider
    private let executor: any LaunchExecuting
    private let sender: any KeystrokeSending
    private let terminal: @MainActor () -> TerminalSettings
    private let frontmost: @MainActor () -> (pid: pid_t, bundleID: String?)?
    private let notify: @MainActor (String) -> Void
    private let copySecret: @MainActor (String) -> Void
    private let prompt: any PasswordPrompting
    private let keysDirectory: URL

    init(
        connections: ConnectionStore, provider: any CredentialProvider, executor: any LaunchExecuting,
        sender: any KeystrokeSending, terminal: @escaping @MainActor () -> TerminalSettings,
        frontmost: @escaping @MainActor () -> (pid: pid_t, bundleID: String?)?,
        notify: @escaping @MainActor (String) -> Void, copySecret: @escaping @MainActor (String) -> Void,
        prompt: any PasswordPrompting, keysDirectory: URL
    ) {
        self.connections = connections
        self.provider = provider
        self.executor = executor
        self.sender = sender
        self.terminal = terminal
        self.frontmost = frontmost
        self.notify = notify
        self.copySecret = copySecret
        self.prompt = prompt
        self.keysDirectory = keysDirectory
    }

    /// `target`: the app the action was started from, which must still be in front to act.
    /// nil means the user clicked in xpnd itself, so there is nothing to guard.
    func connect(_ id: Connection.ID, typedInto target: pid_t?) async {
        let library = connections.library // one snapshot, since the file can change across the awaits
        guard let connection = library.connection(id) else { return notify("That connection no longer exists.") }
        guard let plan = plan(for: connection, in: library),
              await fetchMissingKeys(for: connection, in: library),
              await launch(plan, into: target) else { return }
        await copyPasswords(for: connection, in: library)
    }

    /// Runs first, before any provider call: a connection that can't be built shouldn't ask for Touch ID.
    private func plan(for connection: Connection, in library: ConnectionLibrary) -> LaunchPlan? {
        do throws(LaunchError) {
            if connection.type == .vnc {
                return .openURL(try LaunchPlanner.vncURL(
                    host: connection.host, port: connection.effectivePort, user: library.loginUser(for: connection)))
            }
            let command: SSHCommand
            do throws(SSHCommandError) {
                command = try SSHCommandBuilder.build(connection.id, in: library, keysDirectory: keysDirectory)
            } catch {
                notify(error.message)
                return nil
            }
            return try LaunchPlanner.plan(command, frontBundleID: frontmost()?.bundleID, settings: terminal())
        } catch {
            notify(error.message)
            return nil
        }
    }

    /// Every hop's `-i` names its own key file. `plan` has already refused jump cycles, so the walk ends.
    private func fetchMissingKeys(for connection: Connection, in library: ConnectionLibrary) async -> Bool {
        guard connection.type == .ssh else { return true }
        var hops = [connection]
        while case .connection(let id)? = hops.last?.jumpHost, let next = library.connection(id) { hops.append(next) }
        for hop in hops {
            guard let ref = library.loginCredential(for: hop.id)?.ref, ref.category == .sshKey else { continue }
            let file = SSHCommandBuilder.keyFile(ref, in: keysDirectory)
            if FileManager.default.fileExists(atPath: file.path) { continue }
            let key: String
            do throws(CredentialError) {
                key = try await provider.publicKey(for: ref)
            } catch {
                notify(error.message)
                return false
            }
            do {
                try FileManager.default.createDirectory(at: keysDirectory, withIntermediateDirectories: true)
                try Data(key.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            } catch {
                notify("xpnd couldn't save the public key for “\(ref.title)”.")
                return false
            }
        }
        return true
    }

    /// Checks the front app here, after any Touch ID prompt for a key has had its chance to move focus.
    private func launch(_ plan: LaunchPlan, into target: pid_t?) async -> Bool {
        if let target, frontmost()?.pid != target {
            notify(ExpansionError.targetAppChanged.message)
            return false
        }
        if case .typeIntoFrontTerminal(let line) = plan {
            await sender.paste(line)
            await sender.press(.enter, times: 1)
            return true
        }
        do throws(LaunchError) {
            try await executor.execute(plan)
            return true
        } catch {
            notify(error.message)
            return false
        }
    }

    private func copyPasswords(for connection: Connection, in library: ConnectionLibrary) async {
        let name = connection.name
        let login = library.loginCredential(for: connection.id)?.ref
        let needsLogin = connection.type == .vnc ? login != nil : login?.hasPassword == true
        if needsLogin, let login {
            guard await copyPassword(login) else { return }
            notify("Password copied for \(name)")
        }
        guard connection.type == .ssh, connection.autoSudo else { return }
        guard let sudo = library.sudoCredential(for: connection.id)?.ref, sudo.hasPassword else {
            return notify("No sudo password set for \(name)")
        }
        // A copy now would replace the login password before it's been pasted.
        if needsLogin, !(await prompt.offerSudo(for: name)) { return }
        if await copyPassword(sudo) { notify("Sudo password copied") }
    }

    private func copyPassword(_ ref: CredentialRef) async -> Bool {
        do throws(CredentialError) {
            copySecret(try await provider.password(for: ref))
            return true
        } catch {
            notify(error.message)
            return false
        }
    }
}
