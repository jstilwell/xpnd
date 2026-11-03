import AppKit
import SwiftUI

@MainActor @Observable
final class MainWindowModel {
    var selection: SidebarItem?
}

/// The main window: connections and snippets in the sidebar, the selection's Details on the right.
/// xpnd has a Dock icon only while it's open.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let model: MainWindowModel

    init(store: SnippetStore, connections: ConnectionStore, connect: @escaping (Connection.ID) -> Void) {
        let model = MainWindowModel()
        self.model = model
        let host = NSHostingController(rootView: MainView(
            model: model, connections: connections, editing: SnippetEditing(store: store), connect: connect))
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

    /// Back to menu-bar only; xpnd keeps running.
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MainView: View {
    @Bindable var model: MainWindowModel
    let connections: ConnectionStore
    let editing: SnippetEditing
    let connect: (Connection.ID) -> Void
    /// A reload from disk gives snippets new ids, so the selected group or snippet is found again by
    /// its name or keyword.
    @State private var selectedName: String?

    var body: some View {
        NavigationSplitView {
            Sidebar(connections: connections, editing: editing, selection: $model.selection, connect: connect)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            DetailsPane(connections: connections, editing: editing, selection: $model.selection, connect: connect)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onChange(of: editing.store.library) { reselect() }
        .onChange(of: model.selection, initial: true) { remember() }
    }

    private func remember() {
        selectedName = switch model.selection {
        case .snippetGroup(let id): editing.group(id)?.name
        case .snippet(let id): editing.snippet(id)?.keyword
        default: nil
        }
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
