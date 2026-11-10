import SwiftUI

/// The right side of the main window: Details, which edits the sidebar's selection. Sessions have their
/// own tabs in `TerminalWorkspace`, which shows this as a card over them.
struct DetailsPane: View {
    let connections: ConnectionEditing
    let editing: SnippetEditing
    let sessions: TerminalSessions
    @Binding var selection: SidebarItem?
    @Binding var focus: EditorFocus?
    /// Deletes an item, asking first when there is something to lose.
    let delete: (SidebarItem) -> Void

    var body: some View {
        TabView {
            details.tabItem { Text("Details") }
        }
        .padding(8)
    }

    @ViewBuilder private var details: some View {
        switch selection {
        case .folder(let id):
            if let folder = connections.library.folder(id) {
                // Per-item ids, so one editor's unsaved field state never shows on another.
                chrome(connections.store.loadError, connections.saveProblem, file: "connections.yaml") { FolderEditorView(editing: connections, folder: folder, focus: $focus).id(id) }
            } else { nothingSelected }
        case .connection(let id):
            if let connection = connections.library.connection(id) {
                chrome(connections.store.loadError, connections.saveProblem, file: "connections.yaml") { ConnectionEditorView(editing: connections, connection: connection, live: sessions.liveConnectionIDs.contains(id), hasSession: sessions.session(for: id) != nil, focus: $focus) { delete(.connection(id)) }.id(id) }
            } else { nothingSelected }
        case .snippetGroup(let id):
            if let group = editing.group(id) {
                chrome(editing.store.loadError, editing.saveProblem, file: "snippets.yaml") { SnippetGroupDetails(editing: editing, group: group, connections: connections.library, selection: $selection) { delete(.snippetGroup(id)) } }
            } else { nothingSelected }
        case .snippet(let id):
            if let snippet = editing.snippet(id) {
                chrome(editing.store.loadError, editing.saveProblem, file: "snippets.yaml") { SnippetDetails(editing: editing, snippet: snippet, connections: connections.library) { delete(.snippet(id)) } }
            } else { nothingSelected }
        case nil:
            nothingSelected
        }
    }

    private var nothingSelected: some View {
        ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left")
    }

    /// An editor between its file's banners (a load error, a refused save) and the footnote saying where it saves.
    private func chrome(_ loadError: String?, _ saveProblem: String?, file: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError {
                Label("\(file) has an error, so editing is off until it's fixed: \(loadError)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).lineLimit(4).padding(8)
            }
            if let saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.circle").foregroundStyle(.red).padding(8)
            }
            content()
            Text("Saved to ~/Library/Application Support/xpnd/\(file). Saving from xpnd rewrites the file and drops comments.")
                .font(.callout).foregroundStyle(.secondary).padding(8)
        }
    }
}
