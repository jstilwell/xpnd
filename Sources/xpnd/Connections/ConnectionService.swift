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
    /// Asked at each use, so a changed op path in Settings applies at once.
    private let provider: @MainActor () -> any CredentialProvider
    private let executor: any LaunchExecuting
    private let openTab: @MainActor (TabRequest, Connection) -> Void
    private let sender: any KeystrokeSending
    private let terminal: @MainActor () -> TerminalSettings
    private let remoteDesktop: @MainActor () -> RDPSettings
    private let frontmost: @MainActor () -> (pid: pid_t, bundleID: String?)?
    private let notify: @MainActor (String) -> Void
    private let copySecret: @MainActor (String) async -> Void
    private let prompt: any PasswordPrompting
    private let keysDirectory: URL
    /// Runs after `connect` returns, so Touch ID and the sudo offer never hold the engine's one-action claim.
    private(set) var passwordPhase: Task<Void, Never>?

    init(
        connections: ConnectionStore, provider: @escaping @MainActor () -> any CredentialProvider, executor: any LaunchExecuting,
        openTab: @escaping @MainActor (TabRequest, Connection) -> Void, sender: any KeystrokeSending, terminal: @escaping @MainActor () -> TerminalSettings,
        remoteDesktop: @escaping @MainActor () -> RDPSettings, frontmost: @escaping @MainActor () -> (pid: pid_t, bundleID: String?)?,
        notify: @escaping @MainActor (String) -> Void, copySecret: @escaping @MainActor (String) async -> Void,
        prompt: any PasswordPrompting, keysDirectory: URL
    ) {
        self.connections = connections
        self.provider = provider
        self.executor = executor
        self.openTab = openTab
        self.sender = sender
        self.terminal = terminal
        self.remoteDesktop = remoteDesktop
        self.frontmost = frontmost
        self.notify = notify
        self.copySecret = copySecret
        self.prompt = prompt
        self.keysDirectory = keysDirectory
    }

    func cancelPasswordPhase() {
        passwordPhase?.cancel()
        passwordPhase = nil
    }

    /// `target`: the app the action was started from, which must still be in front to act.
    /// nil means the user clicked in xpnd itself, so there is nothing to guard.
    /// `deletingCharacters`: a typed string still sitting in that app (a folder's), deleted right before acting.
    /// `sudo`: ⌘ was held on the pick, so this connect runs with auto-sudo on whatever the saved setting is
    /// (nothing for RDP).
    func connect(_ id: Connection.ID, typedInto target: pid_t?, deletingCharacters: Int = 0, sudo: Bool = false,
                 preferBuiltIn: Bool = false) async {
        cancelPasswordPhase()
        var library = connections.library // one snapshot, since the file can change across the awaits
        if sudo { library.editConnection(id) { $0.autoSudo = true } }
        guard let connection = library.connection(id) else { return notify("That connection no longer exists.") }
        guard let plan = plan(for: connection, in: library, preferBuiltIn: preferBuiltIn),
              await fetchMissingKeys(for: connection, in: library) else { return }
        if case .rdpTab(let config) = plan {
            return await openRemoteDesktop(config, for: connection, in: library, into: target, deletingCharacters: deletingCharacters)
        }
        guard await launch(plan, for: connection, into: target, deletingCharacters: deletingCharacters) else { return }
        passwordPhase = Task { await copyPasswords(for: connection, in: library) }
    }

    /// The passwords are fetched before the tab exists, so Touch ID comes first, and go into the
    /// tab's session only: nothing is copied. No credential opens the tab with "" and FreeRDP asks.
    private func openRemoteDesktop(_ config: RDPSessionConfig, for connection: Connection, in library: ConnectionLibrary,
                                   into target: pid_t?, deletingCharacters: Int) async {
        var password = "", gatewayPassword: String?
        do throws(CredentialError) {
            if let login = library.loginCredential(for: connection.id)?.ref, login.hasPassword {
                password = try await provider().password(for: login)
            }
            if let gateway = config.gateway?.credential {
                gatewayPassword = try await provider().password(for: gateway)
            }
        } catch {
            return notify(error.message)
        }
        guard await prepareToAct(into: target, deletingCharacters: deletingCharacters) else { return }
        openTab(.remoteDesktop(config, password: password, gatewayPassword: gatewayPassword), connection)
    }

    /// Runs first, before any provider call: a connection that can't be built shouldn't ask for Touch ID.
    private func plan(for connection: Connection, in library: ConnectionLibrary, preferBuiltIn: Bool) -> LaunchPlan? {
        do throws(LaunchError) {
            if connection.type == .vnc {
                return .openURL(try LaunchPlanner.vncURL(
                    host: connection.host, port: connection.effectivePort, user: library.loginUser(for: connection)))
            }
            if connection.type == .rdp {
                return .rdpTab((connection.rdp ?? RDPOptions()).resolved(
                    over: remoteDesktop(), host: connection.host, port: connection.effectivePort,
                    username: library.loginUser(for: connection), domain: connection.domain))
            }
            let command: SSHCommand
            do throws(SSHCommandError) {
                command = try SSHCommandBuilder.build(connection.id, in: library, keysDirectory: keysDirectory)
            } catch {
                notify(error.message)
                return nil
            }
            return try LaunchPlanner.plan(command, frontBundleID: frontmost()?.bundleID, settings: terminal(), preferBuiltIn: preferBuiltIn)
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
            // The item comes from a hand-editable file and names a path, for us and for ssh's -i.
            guard CredentialRef.isSafe(ref.item) else {
                notify(CredentialError.invalidRef.message)
                return false
            }
            let file = SSHCommandBuilder.keyFile(ref, in: keysDirectory)
            if FileManager.default.fileExists(atPath: file.path) { continue }
            let key: String
            do throws(CredentialError) {
                key = try await provider().publicKey(for: ref)
            } catch {
                notify(error.message)
                return false
            }
            do {
                try SSHCommandBuilder.writeKeyFile(key, for: ref, in: keysDirectory)
            } catch {
                notify("xpnd couldn't save the public key for “\(ref.title)”.")
                return false
            }
        }
        return true
    }

    /// Checks the front app here, after any Touch ID prompt for a key has had its chance to move focus.
    private func launch(_ plan: LaunchPlan, for connection: Connection, into target: pid_t?, deletingCharacters: Int) async -> Bool {
        guard await prepareToAct(into: target, deletingCharacters: deletingCharacters) else { return false }
        if case .builtInTab(let command) = plan {
            openTab(.terminal(command), connection)
            return true
        }
        if case .typeIntoFrontTerminal(let line) = plan {
            await sender.paste(line)
            guard stillInFront(target) else { return false } // paste takes ~150 ms, and Return would go to whatever is in front
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

    private func prepareToAct(into target: pid_t?, deletingCharacters: Int) async -> Bool {
        guard stillInFront(target) else { return false }
        if deletingCharacters > 0 { await sender.backspace(times: deletingCharacters) }
        return true
    }

    private func stillInFront(_ target: pid_t?) -> Bool {
        guard let target, frontmost()?.pid != target else { return true }
        notify(ExpansionError.targetAppChanged.message)
        return false
    }

    private func copyPasswords(for connection: Connection, in library: ConnectionLibrary) async {
        let name = connection.name
        let login = library.loginCredential(for: connection.id)?.ref
        let needsLogin = login?.hasPassword == true
        if needsLogin, let login {
            guard await copyPassword(login) else { return }
            notify("Password copied for \(name)")
        }
        // Screen Sharing always asks for a password; an SSH login may well need none.
        if connection.type == .vnc, !needsLogin { return notify("No password set for \(name)") }
        guard connection.type == .ssh, connection.autoSudo else { return }
        guard let sudo = library.sudoCredential(for: connection.id)?.ref, sudo.hasPassword else {
            return notify("No sudo password set for \(name)")
        }
        // A copy now would replace the login password before it's been pasted.
        if needsLogin, !(await prompt.offerSudo(for: name)) { return }
        if await copyPassword(sudo) { notify("Sudo password copied") }
    }

    /// False if there's nothing more to do. Once cancelled, a newer connection owns the clipboard
    /// and the HUD, so this one stays silent.
    private func copyPassword(_ ref: CredentialRef) async -> Bool {
        do throws(CredentialError) {
            let password = try await provider().password(for: ref)
            guard !Task.isCancelled else { return false }
            await copySecret(password)
            return !Task.isCancelled
        } catch {
            if !Task.isCancelled { notify(error.message) }
            return false
        }
    }
}
