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
    let sessions = TerminalSessions(makeHost: { LiveTerminalHost(command: $0, settings: AppSettings.shared.builtInTerminal) })
    private let cancelPasswordPhase: () -> Void

    init(store: SnippetStore, connections: ConnectionStore, provider: @escaping @MainActor () -> any CredentialProvider,
         preferredAccount: @escaping @MainActor () -> String?, keysDirectory: URL,
         connect: @escaping (Connection.ID, _ sudo: Bool) -> Void, duplicate: @escaping (Connection.ID) -> Void,
         cancelPasswordPhase: @escaping () -> Void, openSettings: @escaping () -> Void) {
        let model = MainWindowModel()
        self.model = model
        self.cancelPasswordPhase = cancelPasswordPhase
        let editing = ConnectionEditing(
            store: connections, snippets: store, provider: provider, preferredAccount: preferredAccount,
            keysDirectory: keysDirectory, connect: { id, sudo in
                connect(id, sudo)
                model.hideEditor()
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
    func openTab(_ command: SSHCommand, for connection: Connection, color: ItemColor?) {
        model.hideEditor()
        show(selecting: nil)
        sessions.open(command, for: connection, color: color)
    }

    /// Whether the keyboard is in a session's terminal.
    var terminalHasFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return sessions.sessions.contains { responder.isDescendant(of: $0.host.view) }
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

    var body: some View {
        NavigationSplitView {
            Sidebar(connections: connections, editing: editing, selection: $model.selection, focus: $model.focus,
                    openSettings: openSettings)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            Group {
                if sessions.sessions.isEmpty {
                    details
                } else {
                    TerminalWorkspace(sessions: sessions, duplicate: duplicate, settings: AppSettings.shared.builtInTerminal)
                        .overlay { if model.editorShown { editorCard } }
                }
            }
            .navigationSplitViewColumnWidth(min: 480, ideal: 700)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onChange(of: model.selection) { if !sessions.sessions.isEmpty && model.selection != nil { model.editorShown = true } }
        // The next first tab shows its terminal, not a card left over from the last ones.
        .onChange(of: sessions.sessions.isEmpty) { model.hideEditor() }
        .onChange(of: editing.store.library) { reselect() }
        .onChange(of: connections.library) { reselectConnection() }
        .onChange(of: model.selection, initial: true) { remember() }
    }

    private var details: some View {
        DetailsPane(connections: connections, editing: editing, selection: $model.selection, focus: $model.focus)
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
