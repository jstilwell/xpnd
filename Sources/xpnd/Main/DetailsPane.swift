import SwiftUI

/// The right side of the main window: a tab strip whose first tab, Details, edits the sidebar's
/// selection. Later projects add session tabs.
struct DetailsPane: View {
    let connections: ConnectionEditing
    let editing: SnippetEditing
    @Binding var selection: SidebarItem?
    @Binding var focus: EditorFocus?

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
                connectionChrome { FolderEditorView(editing: connections, folder: folder, focus: $focus).id(id) }
            } else { nothingSelected }
        case .connection(let id):
            if let connection = connections.library.connection(id) {
                connectionChrome { ConnectionEditorView(editing: connections, connection: connection, focus: $focus).id(id) }
            } else { nothingSelected }
        case .snippetGroup(let id):
            if let group = editing.group(id) {
                snippetChrome { SnippetGroupDetails(editing: editing, group: group, selection: $selection) }
            } else { nothingSelected }
        case .snippet(let id):
            if let snippet = editing.snippet(id) {
                snippetChrome { SnippetDetails(editing: editing, snippet: snippet, connections: connections.library, selection: $selection) }
            } else { nothingSelected }
        case nil:
            nothingSelected
        }
    }

    private var nothingSelected: some View {
        ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left")
    }

    /// The connection editors' banners and footnote, matching the snippet editors'.
    private func connectionChrome(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError = connections.store.loadError {
                Label("connections.yaml has an error, so editing is off until it's fixed: \(loadError)",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).lineLimit(4).padding(8)
            }
            if let saveProblem = connections.saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.circle").foregroundStyle(.red).padding(8)
            }
            content()
            Text("Saved to ~/Library/Application Support/xpnd/connections.yaml. Saving from xpnd rewrites the file and drops comments.")
                .font(.callout).foregroundStyle(.secondary).padding(8)
        }
    }

    /// The snippet editors' banners and footnote, as the Snippets settings tab had them.
    private func snippetChrome(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let loadError = editing.store.loadError {
                Label("snippets.yaml has an error, so editing is off until it's fixed: \(loadError)",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled).lineLimit(4).padding(8)
            }
            if let saveProblem = editing.saveProblem {
                Label(saveProblem, systemImage: "exclamationmark.circle").foregroundStyle(.red).padding(8)
            }
            content()
            Text("Saved to ~/Library/Application Support/xpnd/snippets.yaml. Saving from xpnd rewrites the file and drops comments.")
                .font(.callout).foregroundStyle(.secondary).padding(8)
        }
    }
}
