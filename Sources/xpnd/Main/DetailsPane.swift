import SwiftUI

/// The right side of the main window: a tab strip whose first tab, Details, edits the sidebar's
/// selection. Later projects add session tabs.
struct DetailsPane: View {
    let connections: ConnectionStore
    let editing: SnippetEditing
    @Binding var selection: SidebarItem?
    let connect: (Connection.ID) -> Void

    var body: some View {
        TabView {
            details.tabItem { Text("Details") }
        }
        .padding(8)
    }

    @ViewBuilder private var details: some View {
        switch selection {
        case .folder(let id):
            if let folder = connections.library.folder(id) { folderDetails(folder) } else { nothingSelected }
        case .connection(let id):
            if let connection = connections.library.connection(id) { connectionDetails(connection) } else { nothingSelected }
        case .snippetGroup(let id):
            if let group = editing.group(id) {
                snippetChrome { SnippetGroupDetails(editing: editing, group: group, selection: $selection) }
            } else { nothingSelected }
        case .snippet(let id):
            if let snippet = editing.snippet(id) {
                snippetChrome { SnippetDetails(editing: editing, snippet: snippet, selection: $selection) }
            } else { nothingSelected }
        case nil:
            nothingSelected
        }
    }

    private var nothingSelected: some View {
        ContentUnavailableView("Nothing Selected", systemImage: "sidebar.left")
    }

    // Task 14 replaces these two with the folder and connection editors.
    private func folderDetails(_ folder: ConnectionFolder) -> some View {
        let activation = KeywordNamespace(snippets: editing.store.library, connections: connections.library)
            .effectiveActivation(ofFolder: folder.id)
        return Form {
            LabeledContent("Name", value: folder.name)
            LabeledContent("Activation string", value: activation.string ?? "None")
            if let reason = activation.reason { Text(reason).font(.callout).foregroundStyle(.secondary) }
            Text("Editing comes in the next task").foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func connectionDetails(_ connection: Connection) -> some View {
        Form {
            LabeledContent("Name", value: connection.name)
            LabeledContent("Type", value: connection.type.rawValue)
            LabeledContent("Host", value: connection.host)
            Button("Connect") { connect(connection.id) }
            Text("Editing comes in the next task").foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
