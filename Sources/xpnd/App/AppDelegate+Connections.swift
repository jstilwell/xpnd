import AppKit

/// Connecting, the quick menu, and the main window. Every connect runs as the engine's one action.
extension AppDelegate {
    func makeConnectionService(sender: CGEventKeystrokeSender) -> ConnectionService {
        let hud = hud
        return ConnectionService(
            connections: connections,
            provider: { [unowned self] in self.provider },
            executor: LiveLaunchExecutor(), openTab: { _, _ in }, sender: sender,
            terminal: { AppSettings.shared.terminal },
            frontmost: { NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) } },
            notify: { hud.flash($0) },
            copySecret: { [weak self] secret in await self?.engine.whenIdle { SecretClipboard.copy(secret) } },
            prompt: PasswordPrompt(),
            keysDirectory: keysDirectory
        )
    }

    var keysDirectory: URL { ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "keys") }

    /// A typed activation string, already inside the engine's claim. `typed`: characters of a folder
    /// string still in the app, deleted when a row is picked (Esc leaves them, like a cancelled form).
    func activate(_ target: ActivationTarget, typedInto pid: pid_t?, typed: Int) async {
        let library = connections.library
        switch target {
        case .connection(let id):
            guard library.connection(id) != nil else { return hud.flash("That connection no longer exists.") }
            await service.connect(id, typedInto: pid)
        case .folder(let id):
            guard library.folder(id) != nil else { return hud.flash("That folder no longer exists.") }
            quickMenu.show(
                folder: id, library: library,
                onOpenApp: { [weak self] in self?.showMainWindow(selecting: .folder(id)) },
                connect: { [weak self] connection, pid, sudo in
                    await self?.connectExclusively(connection, from: pid, deleting: typed, sudo: sudo)
                }
            )
        }
    }

    /// For the quick menu, the launcher and the main window. `pid`: the app to guard, nil for none.
    func connectExclusively(_ id: Connection.ID, from pid: pid_t?, deleting: Int = 0, sudo: Bool = false,
                           preferBuiltIn: Bool = false) async {
        let service = service
        guard await engine.exclusive({ await service?.connect(id, typedInto: pid, deletingCharacters: deleting, sudo: sudo, preferBuiltIn: preferBuiltIn) }) else {
            return hud.flash("Another action is still running.")
        }
    }

    func showMainWindow(selecting item: SidebarItem?) {
        if mainWindow == nil {
            mainWindow = MainWindowController(
                store: store, connections: connections,
                provider: { [unowned self] in self.provider }, preferredAccount: { AppSettings.shared.onePasswordAccount },
                keysDirectory: keysDirectory,
                connect: { [weak self] id, sudo in
                    // Clicked in xpnd itself, so there's no other app to guard.
                    Task { await self?.connectExclusively(id, from: nil, sudo: sudo) }
                },
                openSettings: { [weak self] in self?.showSettings() })
        }
        mainWindow?.show(selecting: item)
    }

    @objc func openMainWindow() {
        showMainWindow(selecting: nil)
    }

    /// Flashes once when a string is owned in both files, and again only when the set changes.
    func followCrossFileDuplicates() {
        let duplicates = withObservationTracking {
            KeywordNamespace(snippets: store.library, connections: connections.library).crossFileDuplicates
        } onChange: { [weak self] in
            Task { @MainActor in self?.followCrossFileDuplicates() }
        }
        guard duplicates != flaggedDuplicates else { return }
        flaggedDuplicates = duplicates
        if let first = duplicates.sorted().first {
            hud.flash("“\(first)” is used by both a snippet and a connection, so it does nothing until you change one.")
        }
    }
}
