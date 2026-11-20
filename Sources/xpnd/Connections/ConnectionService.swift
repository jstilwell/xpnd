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
    private let showCopied: @MainActor (String, TerminalSession.ID) -> Void
    private let tabPasswords: @MainActor () -> TabPasswordMode
    /// Offers a password over a built-in tab; true once it went in.
    private let offerInTab: @MainActor (_ label: String, _ password: String, TerminalSession.ID, _ automatic: Bool) async -> Bool
    private let copySecret: @MainActor (String) async -> Void
    private let prompt: any PasswordPrompting
    private let keysDirectory: URL
    private let sshConnectDefaults: @MainActor () -> Bool
    /// Shows (true) or takes down (false, if it still shows) a message while a password manager is asked.
    private let waiting: @MainActor (String, Bool) -> Void
    /// Once something launched or opened, for the launcher's Recent list.
    private let recordRecent: @MainActor (Connection.ID) -> Void
    // Both run after `connect` returns, so Touch ID and the sudo offer never hold the engine's one-action claim.
    /// Copies to the clipboard: the next connect cancels it, since its own passwords take the clipboard.
    private(set) var passwordPhase: Task<Void, Never>?
    /// Offers into a tab, or a desktop's password fetch then its tab: each belongs to its own tab, so a later connect
    /// leaves it alone.
    // shortcut: only the latest is kept, so closing the window cancels that one and earlier ones run on (offers end with their tabs); keep a set if a desktop opening after a close bites.
    private(set) var tabPhase: Task<Void, Never>?

    init(
        connections: ConnectionStore, provider: @escaping @MainActor () -> any CredentialProvider, executor: any LaunchExecuting,
        openTab: @escaping @MainActor (TabRequest, Connection) -> TerminalSession.ID?, sender: any KeystrokeSending, terminal: @escaping @MainActor () -> TerminalSettings,
        remoteDesktop: @escaping @MainActor () -> RDPSettings, frontmost: @escaping @MainActor () -> (pid: pid_t, bundleID: String?)?,
        notify: @escaping @MainActor (String) -> Void, showCopied: @escaping @MainActor (String, TerminalSession.ID) -> Void = { _, _ in },
        tabPasswords: @escaping @MainActor () -> TabPasswordMode = { .clipboard },
        offerInTab: @escaping @MainActor (String, String, TerminalSession.ID, Bool) async -> Bool = { _, _, _, _ in false },
        copySecret: @escaping @MainActor (String) async -> Void, prompt: any PasswordPrompting, keysDirectory: URL,
        sshConnectDefaults: @escaping @MainActor () -> Bool = { false },
        waiting: @escaping @MainActor (String, Bool) -> Void = { _, _ in },
        recordRecent: @escaping @MainActor (Connection.ID) -> Void = { _ in }
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
        self.sshConnectDefaults = sshConnectDefaults
        self.waiting = waiting
        self.recordRecent = recordRecent
    }

    /// Where a connect went: a built-in tab (which its passwords can be sent into), or another app.
    private enum Launched { case tab(TerminalSession.ID), elsewhere }

    /// Both phases: the window is closing.
    func cancelPasswordPhase() {
        passwordPhase?.cancel()
        passwordPhase = nil
        tabPhase?.cancel()
        tabPhase = nil
    }

    /// `target`: the app the action was started from, which must still be in front to act.
    /// nil means the user clicked in xpnd itself, so there is nothing to guard.
    /// `deletingCharacters`: a typed string still sitting in that app (a folder's), deleted right before acting.
    /// `sudo`: ⌘ was held on the pick, so this connect runs with auto-sudo on whatever the saved setting is
    /// (nothing for RDP).
    func connect(_ id: Connection.ID, typedInto target: pid_t?, deletingCharacters: Int = 0, sudo: Bool = false,
                 preferBuiltIn: Bool = false) async {
        passwordPhase?.cancel()
        passwordPhase = nil
        var library = connections.library // one snapshot, since the file can change across the awaits
        if sudo { library.editConnection(id) { $0.autoSudo = true } }
        guard let connection = library.connection(id) else { return notify("That connection no longer exists.") }
        guard let plan = plan(for: connection, in: library, preferBuiltIn: preferBuiltIn),
              await fetchMissingKeys(for: connection, in: library) else { return }
        if case .rdpTab(let config) = plan {
            // The typed string goes now, from the app it was typed in; the tab is xpnd's own, so it can open later.
            guard await prepareToAct(into: target, deletingCharacters: deletingCharacters) else { return }
            tabPhase = Task { await openRemoteDesktop(config, for: connection, in: library) }
            return
        }
        guard let launched = await launch(plan, for: connection, into: target, deletingCharacters: deletingCharacters) else { return }
        recordRecent(connection.id)
        if case .tab(let tab) = launched, tabPasswords() != .clipboard {
            let automatic = tabPasswords() == .sendAutomatically
            tabPhase = Task { await offerPasswords(for: connection, in: library, tab: tab, automatic: automatic) }
        } else {
            let tab: TerminalSession.ID? = if case .tab(let id) = launched { id } else { nil }
            passwordPhase = Task { await copyPasswords(for: connection, in: library, tab: tab) }
        }
    }

    static func waitingText(for ref: CredentialRef) -> String {
        ref.provider == KeychainProvider.id ? "Waiting for the Keychain…" : "Waiting for 1Password…"
    }

    /// The passwords are fetched before the tab exists and go into the tab's session only: nothing is copied. A
    /// password that isn't there ("") is left unset, so FreeRDP asks for it; any other failure opens nothing.
    private func openRemoteDesktop(_ config: RDPSessionConfig, for connection: Connection, in library: ConnectionLibrary) async {
        let login = library.loginCredential(for: connection.id).map(\.ref).flatMap { $0.hasPassword ? $0 : nil }
        let asked = (login ?? config.gateway?.credential).map(Self.waitingText)
        if let asked { waiting(asked, true) }
        var missing: String?
        func fetch(_ ref: CredentialRef) async throws(CredentialError) -> String {
            do throws(CredentialError) {
                return try await provider().password(for: ref)
            } catch {
                switch error {
                case .notFound, .noPassword:
                    missing = missing ?? error.message
                    return ""
                default: throw error
                }
            }
        }
        let passwords: Result<(String, String?), CredentialError>
        do throws(CredentialError) {
            let password = if let login { try await fetch(login) } else { "" }
            // Same credentials: FreeRDP's core never copies the login password to the gateway itself.
            let gateway: String? = if let gateway = config.gateway {
                if let ref = gateway.credential { try await fetch(ref) } else { password }
            } else { nil }
            passwords = .success((password, gateway))
        } catch {
            passwords = .failure(error)
        }
        if let asked { waiting(asked, false) }
        guard !Task.isCancelled else { return }
        switch passwords {
        case .failure(let error):
            notify(error.message)
        case .success(let (password, gateway)):
            if let missing { notify(missing + " Windows will ask for the password.") }
            if openTab(.remoteDesktop(config, password: password, gatewayPassword: gateway), connection) != nil { recordRecent(connection.id) }
        }
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
                command = try SSHCommandBuilder.build(connection.id, in: library, keysDirectory: keysDirectory,
                                                       connectDefaults: sshConnectDefaults())
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
            await sender.restoreClipboard()
            guard stillInFront(target) else { return nil } // a paste waits for the app to read it, and Return would go to whatever is in front
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
        let name = connection.name
        let login = library.loginCredential(for: connection.id)?.ref
        let needsLogin = login?.hasPassword == true
        if needsLogin, let login {
            guard await copyPassword(login) else { return }
            notify("Password copied for \(name)")
            if let tab { showCopied("Password copied", tab) }
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
            if let tab { showCopied("Sudo password copied", tab) }
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
