import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    private(set) var menu = NSMenu()

    private static let snippetsErrorMessage =
        "xpnd couldn't read snippets.yaml, so snippets are paused (connection strings still work). Fix the file and it reloads automatically."
    private static let connectionsErrorMessage =
        "xpnd couldn't read connections.yaml, so connection strings are paused. Fix the file and it reloads automatically."

    // Not private where AppDelegate+Connections uses them.
    let settings = AppSettings.shared
    let store = SnippetStore(fileURL: SnippetStore.defaultURL)
    let connections = ConnectionStore(fileURL: ConnectionStore.defaultURL)
    private let permissions = PermissionWatcher()
    let hud = HUD()
    var engine: ExpansionEngine!
    var service: ConnectionService!
    /// The 1Password provider for connecting, the main window and Settings. It keeps no state, so
    /// building it from the current op path at each use means no holder keeps a stale path.
    var provider: OnePasswordProvider { OnePasswordProvider(opPath: settings.onePasswordPath) }
    let quickMenu = QuickMenuPanel()
    var mainWindow: MainWindowController?
    /// The cross-file duplicates the HUD last flagged, so it says so once per change.
    var flaggedDuplicates: Set<String> = []
    private var tap: KeyEventTap!
    private var picker: PickerPanel!
    private let pickerHotKey = GlobalShortcut()
    private var launcher: ConnectionLauncherPanel!
    private let launcherHotKey = GlobalShortcut()
    private var welcome: WelcomeWindowController?
    private var settingsWindow: SettingsWindowController?
    /// The picker shortcut last registered, so a settings change re-registers only when it differs.
    private var registeredPickerShortcut: Shortcut?
    private var registeredLauncherShortcut: Shortcut?
    /// Whether the tap has run since launch: losing access after that isn't a first launch.
    private var hasStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "xpnd")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.menu = menu
        installMainMenu()

        store.load()
        store.startWatching()
        connections.load()
        connections.seedIfFirstLaunch(defaults: .standard)
        connections.startWatching()
        let store = store, hud = hud
        let sender = CGEventKeystrokeSender()
        service = makeConnectionService(sender: sender)
        engine = ExpansionEngine(
            store: store, connections: connections, player: Player(sender: sender, actions: ActionRunner()),
            makeContext: { LiveEvaluationContext(library: store.library) },
            notify: { hud.flash($0) },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            onActivate: { [weak self] in await self?.activate($0, typedInto: $1) }
        )
        engine.isEnabled = settings.expansionEnabled
        picker = PickerPanel(store: store, engine: engine)
        pickerHotKey.action = { [weak self] in self?.picker.toggle() }
        registerPickerShortcut()
        launcher = ConnectionLauncherPanel()
        launcherHotKey.action = { [weak self] in
            guard let self else { return }
            launcher.toggle(
                library: connections.library, onOpenApp: { [weak self] in self?.showMainWindow(selecting: nil) },
                connect: { [weak self] id, pid in await self?.connectExclusively(id, from: pid) }
            )
        }
        registerLauncherShortcut()
        followSettings()
        tap = KeyEventTap(
            onKey: { [weak self] in self?.engine.handle($0, targetsXpnd: $1) },
            onMouseDown: { [weak self] in self?.engine.resetBuffer() }
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.resetBuffer() }
        }

        // Updates don't depend on Accessibility, so a release that needs fixing can still be replaced.
        Updates.shared.start()
        followUpdates()
        permissions.onChange = { [weak self] in self?.permissionsChanged() }
        permissions.start()
        permissionsChanged()

        flashLoadErrors(wereBroken: (false, false))
        followLoadErrors()
        followCrossFileDuplicates()
        rebuildMenu()
        // A login-item launch stays in the menu bar; any other opens the window (and the Dock icon).
        if !Self.launchedAsLoginItem() { showMainWindow(selecting: nil) }
        log.info("xpnd launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
        SecretClipboard.clearIfOwned()
    }

    /// Opening the app again (Dock, Finder, Spotlight, or `open`) shows the main window, and the
    /// welcome window while it waits for access.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !permissions.isGranted { showWelcome() }
        showMainWindow(selecting: nil)
        return false
    }

    /// Only readable while launching: the open-application event says whether login started xpnd.
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// The tap runs only while both permissions are on.
    private func permissionsChanged() {
        guard permissions.isGranted else {
            tap.stop()
            engine.resetBuffer()
            showWelcome()
            return
        }
        if tap.start() {
            hasStarted = true
            log.info("listening for keywords")
        } else {
            log.error("event tap could not be created")
            hud.flash("xpnd couldn't start listening for keywords. Quit and reopen xpnd.")
        }
    }

    private func showWelcome() {
        if welcome == nil {
            let controller = WelcomeWindowController(access: permissions, isReturning: hasStarted)
            controller.onClose = { [weak self] in
                guard let self else { return }
                welcome = nil
                // Closed before access was ever on: there's nothing to run.
                if !hasStarted { NSApp.terminate(nil) }
            }
            welcome = controller
        }
        welcome?.show()
    }

    private var broken: (snippets: Bool, connections: Bool) { (store.loadError != nil, connections.loadError != nil) }

    /// Flashes once for each file that has just broken, not again while it stays broken.
    private func flashLoadErrors(wereBroken before: (snippets: Bool, connections: Bool)) {
        if broken.snippets, !before.snippets { hud.flash(Self.snippetsErrorMessage) }
        if broken.connections, !before.connections { hud.flash(Self.connectionsErrorMessage) }
    }

    /// Flashes a message when either file breaks, and keeps the menu's error items current.
    private func followLoadErrors() {
        let before = broken
        withObservationTracking { _ = (store.loadError, connections.loadError) } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.flashLoadErrors(wereBroken: before)
                self.rebuildMenu()
                self.followLoadErrors()
            }
        }
    }

    /// Shown while the main window is open; otherwise it still gives xpnd's windows their editing
    /// and closing shortcuts.
    /// Adapted from HoverEnhance's.
    private func installMainMenu() {
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        let appMenu = NSMenu()
        appMenu.items = [
            settingsItem, .separator(),
            NSMenuItem(title: "Quit xpnd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        let editMenu = NSMenu(title: "Edit")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.items = [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo, .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]
        let windowMenu = NSMenu(title: "Window")
        windowMenu.items = [NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")]
        let main = NSMenu()
        for submenu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }

    private func registerPickerShortcut() {
        registeredPickerShortcut = settings.pickerShortcut
        if !pickerHotKey.register(settings.pickerShortcut) { hud.flash("Picker shortcut is in use by another app") }
    }

    private func registerLauncherShortcut() {
        registeredLauncherShortcut = settings.connectionLauncherShortcut
        if !launcherHotKey.register(settings.connectionLauncherShortcut) {
            hud.flash("Connection launcher shortcut is in use by another app")
        }
    }

    /// Applies changes made in Settings (or the menu) at once.
    private func followSettings() {
        withObservationTracking { _ = (settings.expansionEnabled, settings.pickerShortcut, settings.connectionLauncherShortcut) } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.engine.isEnabled = self.settings.expansionEnabled
                self.engine.resetBuffer()
                if self.settings.pickerShortcut != self.registeredPickerShortcut { self.registerPickerShortcut() }
                if self.settings.connectionLauncherShortcut != self.registeredLauncherShortcut { self.registerLauncherShortcut() }
                self.rebuildMenu()
                self.followSettings()
            }
        }
    }

    private func followUpdates() {
        withObservationTracking { _ = (Updates.shared.isAvailable, Updates.shared.waitingVersion) } onChange: { [weak self] in
            Task { @MainActor in
                self?.rebuildMenu()
                self?.followUpdates()
            }
        }
    }

    /// Later tasks add their items here, above Quit.
    func rebuildMenu() {
        menu.removeAllItems()
        let main = NSMenuItem(title: "Open xpnd…", action: #selector(openMainWindow), keyEquivalent: "")
        main.target = self
        menu.addItem(main)
        // A snippets file error pauses expansion (the error item says why), so the toggle greys out
        // instead of offering a click that would really turn expansion off.
        let toggle = NSMenuItem(
            title: "Expansion On", action: store.loadError == nil ? #selector(toggleExpansion) : nil,
            keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.expansionEnabled ? .on : .off
        menu.addItem(toggle)
        let open = NSMenuItem(title: "Open Picker", action: #selector(openPicker), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let updates = Updates.shared
        if updates.isAvailable {
            let item = NSMenuItem(
                title: updates.waitingVersion.map { "Update to \($0)…" } ?? "Check for Updates…",
                action: #selector(checkForUpdates), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if store.loadError != nil {
            // No action, so the menu shows it disabled.
            menu.addItem(NSMenuItem(title: "Snippets file has an error", action: nil, keyEquivalent: ""))
        }
        if connections.loadError != nil {
            menu.addItem(NSMenuItem(title: "Connections file has an error", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit xpnd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openPicker() {
        picker.toggle()
    }

    @objc private func checkForUpdates() {
        Updates.shared.checkForUpdates()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                settings: settings, store: store,
                connections: ConnectionEditing(
                    store: connections, snippets: store, provider: { [unowned self] in self.provider },
                    preferredAccount: { AppSettings.shared.onePasswordAccount }, keysDirectory: keysDirectory,
                    connect: { _ in }))
        }
        settingsWindow?.show()
    }

    /// `followSettings` applies it.
    @objc private func toggleExpansion() {
        settings.expansionEnabled.toggle()
    }
}
