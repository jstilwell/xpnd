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
    /// The tab it opened, for the password offer that follows; nil if none could be.
    private let openTab: @MainActor (TabRequest, Connection) -> TerminalSession.ID?
    private let sender: any KeystrokeSending
    private let terminal: @MainActor () -> TerminalSettings
    private let remoteDesktop: @MainActor () -> RDPSettings
    private let frontmost: @MainActor () -> (pid: pid_t, bundleID: String?)?
    private let notify: @MainActor (String) -> Void
    /// A password was copied for a connection that opened in a built-in tab, so the tab can say so too.
    private let showCopied: @MainActor (String, Connection.ID) -> Void
    private let tabPasswords: @MainActor () -> TabPasswordMode
    /// Offers a password over a built-in tab; true once it went in.
    private let offerInTab: @MainActor (_ label: String, _ password: String, TerminalSession.ID, _ automatic: Bool) async -> Bool
    private let copySecret: @MainActor (String) async -> Void
    private let prompt: any PasswordPrompting
    private let keysDirectory: URL
    /// Runs after `connect` returns, so Touch ID and the sudo offer never hold the engine's one-action claim.
    private(set) var passwordPhase: Task<Void, Never>?

    init(
        connections: ConnectionStore, provider: @escaping @MainActor () -> any CredentialProvider, executor: any LaunchExecuting,
        openTab: @escaping @MainActor (TabRequest, Connection) -> TerminalSession.ID?, sender: any KeystrokeSending, terminal: @escaping @MainActor () -> TerminalSettings,
        remoteDesktop: @escaping @MainActor () -> RDPSettings, frontmost: @escaping @MainActor () -> (pid: pid_t, bundleID: String?)?,
        notify: @escaping @MainActor (String) -> Void, showCopied: @escaping @MainActor (String, Connection.ID) -> Void = { _, _ in },
        tabPasswords: @escaping @MainActor () -> TabPasswordMode = { .clipboard },
        offerInTab: @escaping @MainActor (String, String, TerminalSession.ID, Bool) async -> Bool = { _, _, _, _ in false },
        copySecret: @escaping @MainActor (String) async -> Void, prompt: any PasswordPrompting, keysDirectory: URL
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
        self.showCopied = showCopied
        self.tabPasswords = tabPasswords
        self.offerInTab = offerInTab
        self.copySecret = copySecret
        self.prompt = prompt
        self.keysDirectory = keysDirectory
    }

    /// Where a connect went: a built-in tab (which its passwords can be sent into), or another app.
    private enum Launched { case tab(TerminalSession.ID), elsewhere }

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
        guard let launched = await launch(plan, for: connection, into: target, deletingCharacters: deletingCharacters) else { return }
        let tab: TerminalSession.ID? = if case .tab(let id) = launched { id } else { nil }
        passwordPhase = Task { await copyPasswords(for: connection, in: library, tab: tab) }
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
            if let gateway = config.gateway {
                // Same credentials: FreeRDP's core never copies the login password to the gateway itself.
                gatewayPassword = if let ref = gateway.credential { try await provider().password(for: ref) } else { password }
            }
        } catch {
            return notify(error.message)
        }
        guard await prepareToAct(into: target, deletingCharacters: deletingCharacters) else { return }
        _ = openTab(.remoteDesktop(config, password: password, gatewayPassword: gatewayPassword), connection)
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
                    username: library.loginUser(for: connection), domain: connection.domain,
                    dropFolder: RDPDropFolder.url(for: connection.id).path))
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
    /// nil when nothing was launched.
    private func launch(_ plan: LaunchPlan, for connection: Connection, into target: pid_t?, deletingCharacters: Int) async -> Launched? {
        guard await prepareToAct(into: target, deletingCharacters: deletingCharacters) else { return nil }
        if case .builtInTab(let command) = plan {
            return openTab(.terminal(command), connection).map(Launched.tab)
        }
        if case .typeIntoFrontTerminal(let line) = plan {
            await sender.paste(line)
            guard stillInFront(target) else { return nil } // paste takes ~150 ms, and Return would go to whatever is in front
            await sender.press(.enter, times: 1)
            return .elsewhere
        }
        do throws(LaunchError) {
            try await executor.execute(plan)
            return .elsewhere
        } catch {
            notify(error.message)
            return nil
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

    private func copyPasswords(for connection: Connection, in library: ConnectionLibrary, tab: TerminalSession.ID?) async {
        let inTab = tab != nil
        if let tab, tabPasswords() != .clipboard {
            return await offerPasswords(for: connection, in: library, tab: tab, automatic: tabPasswords() == .sendAutomatically)
        }
        let name = connection.name
        let login = library.loginCredential(for: connection.id)?.ref
        let needsLogin = login?.hasPassword == true
        if needsLogin, let login {
            guard await copyPassword(login) else { return }
            notify("Password copied for \(name)")
            if inTab { showCopied("Password copied", connection.id) }
        }
        // Screen Sharing always asks for a password; an SSH login may well need none.
        if connection.type == .vnc, !needsLogin { return notify("No password set for \(name)") }
        guard connection.type == .ssh, connection.autoSudo else { return }
        guard let sudo = library.sudoCredential(for: connection.id)?.ref, sudo.hasPassword else {
            return notify("No sudo password set for \(name)")
        }
        // A copy now would replace the login password before it's been pasted.
        if needsLogin, !(await prompt.offerSudo(for: name)) { return }
        if await copyPassword(sudo) {
            notify("Sudo password copied")
            if inTab { showCopied("Sudo password copied", connection.id) }
        }
    }

    /// Into the tab instead of the clipboard: the login password, then (once it went in) the sudo one.
    /// Nothing is copied, so the sudo password needs no "copy it now?" question.
    private func offerPasswords(for connection: Connection, in library: ConnectionLibrary, tab: TerminalSession.ID, automatic: Bool) async {
        if let login = library.loginCredential(for: connection.id)?.ref, login.hasPassword {
            guard let password = await fetchPassword(login),
                  await offerInTab("Password", password, tab, automatic) else { return }
        }
        guard connection.autoSudo else { return }
        guard let sudo = library.sudoCredential(for: connection.id)?.ref, sudo.hasPassword else {
            return notify("No sudo password set for \(connection.name)")
        }
        guard let password = await fetchPassword(sudo) else { return }
        _ = await offerInTab("Sudo password", password, tab, automatic)
    }

    /// nil after telling the user why, or silently once cancelled.
    private func fetchPassword(_ ref: CredentialRef) async -> String? {
        do throws(CredentialError) {
            let password = try await provider().password(for: ref)
            return Task.isCancelled ? nil : password
        } catch {
            if !Task.isCancelled { notify(error.message) }
            return nil
        }
    }

    /// False if there's nothing more to do. Once cancelled, a newer connection owns the clipboard
    /// and the HUD, so this one stays silent.
    private func copyPassword(_ ref: CredentialRef) async -> Bool {
        guard let password = await fetchPassword(ref) else { return false }
        await copySecret(password)
        return !Task.isCancelled
    }
}
