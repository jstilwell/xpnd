import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var statusItem: NSStatusItem!
    private(set) var menu = NSMenu()

    private static let loadErrorMessage =
        "xpnd couldn't read snippets.yaml, so expansion is paused. Fix the file and it reloads automatically."

    private let settings = AppSettings.shared
    private let store = SnippetStore(fileURL: SnippetStore.defaultURL)
    private let permissions = PermissionWatcher()
    private let hud = HUD()
    private var engine: ExpansionEngine!
    private var tap: KeyEventTap!
    private var welcome: WelcomeWindowController?
    /// Whether the tap has run since launch: losing access after that isn't a first launch.
    private var hasStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "xpnd")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.menu = menu

        store.load()
        store.startWatching()
        let store = store, hud = hud
        engine = ExpansionEngine(
            store: store, player: Player(sender: CGEventKeystrokeSender(), actions: ActionRunner()),
            makeContext: { LiveEvaluationContext(library: store.library) },
            notify: { hud.flash($0) }
        )
        engine.isEnabled = settings.expansionEnabled
        tap = KeyEventTap(
            onKey: { [weak self] in self?.engine.handle($0) },
            onMouseDown: { [weak self] in self?.engine.resetBuffer() }
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.resetBuffer() }
        }

        permissions.onChange = { [weak self] in self?.permissionsChanged() }
        permissions.start()
        permissionsChanged()

        if store.loadError != nil { hud.flash(Self.loadErrorMessage) }
        followLoadError()
        rebuildMenu()
        log.info("xpnd launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.stop()
    }

    /// Opening the app again (from Finder, Spotlight, or `open`) shows the welcome window while it
    /// waits for access.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !permissions.isGranted { showWelcome() }
        return false
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

    /// Flashes a message when the snippets file breaks, and keeps the menu's error item current.
    private func followLoadError() {
        withObservationTracking { _ = store.loadError } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.store.loadError != nil { self.hud.flash(Self.loadErrorMessage) }
                self.rebuildMenu()
                self.followLoadError()
            }
        }
    }

    /// Later tasks add their items here, above Quit.
    func rebuildMenu() {
        menu.removeAllItems()
        let toggle = NSMenuItem(title: "Expansion On", action: #selector(toggleExpansion), keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.expansionEnabled ? .on : .off
        menu.addItem(toggle)
        if store.loadError != nil {
            // No action, so the menu shows it disabled.
            menu.addItem(NSMenuItem(title: "Snippets file has an error", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit xpnd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleExpansion() {
        settings.expansionEnabled.toggle()
        engine.isEnabled = settings.expansionEnabled
        engine.resetBuffer()
        rebuildMenu()
    }
}
