import AppKit

/// Connecting, the quick menu, and the main window. Every connect runs as the engine's one action.
extension AppDelegate {
    func makeConnectionService(sender: CGEventKeystrokeSender) -> ConnectionService {
        let hud = hud
        return ConnectionService(
            connections: connections,
            provider: OnePasswordProvider(opPath: nil), // Task 15 adds the op path setting.
            executor: LiveLaunchExecutor(), sender: sender,
            terminal: { AppSettings.shared.terminal },
            frontmost: { NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) } },
            notify: { hud.flash($0) },
            copySecret: { [weak self] secret in await self?.engine.whenIdle { SecretClipboard.copy(secret) } },
            prompt: PasswordPrompt(),
            keysDirectory: keysDirectory
        )
    }

    var keysDirectory: URL { ConnectionStore.defaultURL.deletingLastPathComponent().appending(path: "keys") }

    /// A typed activation string, already inside the engine's claim.
    func activate(_ target: ActivationTarget, typedInto pid: pid_t?) async {
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
                connect: { [weak self] connection, pid in await self?.connectExclusively(connection, from: pid) }
            )
        }
    }

    /// For the quick menu, the launcher and the main window. `pid`: the app to guard, nil for none.
    func connectExclusively(_ id: Connection.ID, from pid: pid_t?) async {
        let service = service
        guard await engine.exclusive({ await service?.connect(id, typedInto: pid) }) else {
            return hud.flash("Another action is still running.")
        }
    }

    func showMainWindow(selecting item: SidebarItem?) {
        if mainWindow == nil {
            mainWindow = MainWindowController(
                store: store, connections: connections,
                provider: OnePasswordProvider(opPath: nil), // Task 15 adds the op path setting.
                keysDirectory: keysDirectory
            ) { [weak self] id in
                // Clicked in xpnd itself, so there's no other app to guard.
                Task { await self?.connectExclusively(id, from: nil) }
            }
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
