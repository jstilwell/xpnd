import AppKit
import SwiftUI

@MainActor @Observable
final class MainWindowModel {
    var selection: SidebarItem?
    /// A field the sidebar asks the Details editor to focus.
    var focus: EditorFocus?
    /// The Details editor, as a card over the terminal while sessions are open.
    var editorShown = false

    /// Clears the selection too, so a click on the same sidebar row opens the card again.
    func hideEditor() {
        editorShown = false
        selection = nil
    }
}

/// The main window: connections and snippets in the sidebar, the selection's Details on the right.
/// xpnd has a Dock icon only while it's open.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: MainWindowModel
    let sessions: TerminalSessions
    private let cancelPasswordPhase: () -> Void

    init(store: SnippetStore, connections: ConnectionStore, provider: @escaping @MainActor () -> any CredentialProvider,
         preferredAccount: @escaping @MainActor () -> String?, keysDirectory: URL,
         connect: @escaping (Connection.ID, _ sudo: Bool) -> Void, duplicate: @escaping (Connection.ID) -> Void,
         cancelPasswordPhase: @escaping () -> Void, openSettings: @escaping () -> Void) {
        let model = MainWindowModel()
        self.model = model
        weak var presenter: NSWindow? // set below, once the window exists
        let sessions = TerminalSessions { request in
            switch request {
            case .terminal(let command):
                LiveTerminalHost(command: command, settings: AppSettings.shared.builtInTerminal)
            case .remoteDesktop(let config, let password, let gatewayPassword):
                RDPHost(config: config, password: password, gatewayPassword: gatewayPassword, presentIn: { presenter })
            }
        }
        self.sessions = sessions
        self.cancelPasswordPhase = cancelPasswordPhase
        let editing = ConnectionEditing(
            store: connections, snippets: store, provider: provider, preferredAccount: preferredAccount,
            keysDirectory: keysDirectory, connect: connect,
            disconnect: { id in
                guard let session = sessions.session(for: id), session.isLive else { return }
                confirmTerminate(count: 1, in: NSApp.keyWindow) { sessions.close(session.id) }
            },
            showSession: { id in
                guard let session = sessions.session(for: id) else { return }
                sessions.selected = session.id
                model.hideEditor()
                sessions.focusSelected()
            })
        let host = NSHostingController(rootView: MainView(
            model: model, connections: editing, editing: SnippetEditing(store: store), sessions: sessions,
            duplicate: duplicate, openSettings: openSettings))
        // The SwiftUI minimum becomes the window's; the user sizes it from there.
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.title = "xpnd"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.isReleasedWhenClosed = false
        presenter = window
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// nil keeps the current selection.
    func show(selecting item: SidebarItem?) {
        if let item { model.selection = item }
        NSApp.setActivationPolicy(.regular)
        window?.showFromMenuBar()
    }

    /// Opens a session's tab over any editor card, and shows the window.
    func openTab(_ request: TabRequest, for connection: Connection, color: ItemColor?) -> TerminalSession.ID {
        model.hideEditor()
        show(selecting: nil)
        return sessions.open(request, for: connection, color: color)
    }

    /// Whether the keyboard is in a session's terminal or desktop.
    var terminalHasFocus: Bool { focusedSessionKind != nil }

    /// The kind of the session whose view holds the first responder. Requires the main window to be key: a window
    /// keeps its first responder after the app deactivates or another window (Settings, a panel) takes key.
    var focusedSessionKind: TerminalSession.Kind? {
        guard let window, window.isKeyWindow, let responder = window.firstResponder as? NSView else { return nil }
        return sessions.sessions.first { responder.isDescendant(of: $0.host.view) }?.kind
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sessions.liveCount > 0 else { return true }
        confirmTerminate(count: sessions.liveCount, in: sender) { [weak self] in
            self?.sessions.terminateAll()
            self?.cancelPasswordPhase()
            sender.close()
        }
        return false
    }

    /// Back to menu-bar only; xpnd keeps running.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MainView: View {
    @Bindable var model: MainWindowModel
    let connections: ConnectionEditing
    let editing: SnippetEditing
    let sessions: TerminalSessions
    let duplicate: (Connection.ID) -> Void
    let openSettings: () -> Void
    /// A reload from disk gives snippets new ids, so the selected group or snippet is found again by
    /// its name or keyword.
    @State private var selectedName: String?
    /// Connections keep their ids, but a hand edit can drop them: then the folder names from the
    /// root (and the connection's name) find the item again.
    @State private var selectedPath: [String]?
    /// An item with something to lose, waiting for its delete to be confirmed.
    @State private var deleting: SidebarItem?

    var body: some View {
        let question = deleting.flatMap { EditorRules.deleteQuestion(for: $0, connections: connections.library, snippets: editing.store.library) }
        NavigationSplitView {
            Sidebar(connections: connections, editing: editing, sessions: sessions, selection: $model.selection, focus: $model.focus,
                    openSettings: openSettings, delete: askDelete)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            Group {
                if sessions.sessions.isEmpty {
                    details
                } else {
                    TerminalWorkspace(sessions: sessions, duplicate: duplicate, settings: AppSettings.shared.builtInTerminal,
                                      saveDisplay: connections.saveDisplay)
                        .overlay { if model.editorShown { editorCard } }
                }
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 700)
        }
        .frame(minWidth: 900, minHeight: 560)
        .confirmationDialog(question?.title ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { item in
            Button("Delete", role: .destructive) { delete(item) }
        } message: { _ in
            Text(question?.message ?? "")
        }
        .onChange(of: model.selection) { if !sessions.sessions.isEmpty && model.selection != nil { model.editorShown = true } }
        // Back to the selected item's Details with the last tab gone; the next first tab shows its terminal.
        .onChange(of: sessions.sessions.isEmpty) { model.editorShown = false }
        // A code-driven selection (the quick menu) opens the card while the terminal still has the keyboard.
        .onChange(of: model.editorShown) { if model.editorShown { sessions.resignFocus() } }
        .onChange(of: editing.store.library) { reselect() }
        .onChange(of: connections.library) { reselectConnection() }
        .onChange(of: model.selection, initial: true) { remember() }
    }

    private var details: some View {
        DetailsPane(connections: connections, editing: editing, sessions: sessions, selection: $model.selection, focus: $model.focus,
                    delete: askDelete)
    }

    /// The one way anything in the window is deleted: a delete can't be undone, so it asks first unless
    /// there is nothing to lose (`EditorRules.deleteQuestion`).
    private func askDelete(_ item: SidebarItem) {
        let question = EditorRules.deleteQuestion(for: item, connections: connections.library, snippets: editing.store.library)
        if question == nil { delete(item) } else { deleting = item }
    }

    /// On failure the item is selected, so its Details shows why. A deleted snippet leaves its group selected.
    private func delete(_ item: SidebarItem) {
        var next: SidebarItem?
        let deleted: Bool
        switch item {
        case .folder, .connection:
            deleted = connections.delete(item)
        case .snippet(let id):
            next = editing.group(containing: id).map { .snippetGroup($0.id) }
            deleted = editing.snippet(id).map(editing.deleteSnippet) ?? false
        case .snippetGroup(let id):
            deleted = editing.group(id).map(editing.deleteGroup) ?? false
        }
        if !deleted { model.selection = item } else if model.selection == item { model.selection = next }
    }

    private var editorCard: some View {
        details
            .padding(.top, 28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                Button("Close") {
                    model.hideEditor()
                    sessions.focusSelected()
                }
                .keyboardShortcut(.cancelAction)
                .padding(8)
            }
            .padding(24)
    }

    private func remember() {
        selectedName = switch model.selection {
        case .snippetGroup(let id): editing.group(id)?.name
        case .snippet(let id): editing.snippet(id)?.keyword
        default: nil
        }
        selectedPath = model.selection.flatMap(connections.library.namePath(of:))
    }

    private func reselectConnection() {
        let library = connections.library
        switch model.selection {
        case .folder(let id) where library.folder(id) == nil:
            model.selection = selectedPath.flatMap(library.folder(atNamePath:)).map { .folder($0.id) }
        case .connection(let id) where library.connection(id) == nil:
            model.selection = selectedPath.flatMap(library.connection(atNamePath:)).map { .connection($0.id) }
        default:
            break
        }
        remember()
    }

    private func reselect() {
        let groups = editing.store.library.groups
        switch model.selection {
        case .snippetGroup(let id) where editing.group(id) == nil:
            model.selection = groups.first { $0.name == selectedName }.map { .snippetGroup($0.id) }
        case .snippet(let id) where editing.snippet(id) == nil:
            model.selection = groups.lazy.flatMap(\.snippets).first { $0.keyword == selectedName }.map { .snippet($0.id) }
        default:
            break
        }
        // Follows in-app renames, so the next reload can still find them.
        remember()
    }
}
