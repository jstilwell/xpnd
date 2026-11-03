import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Snippets or connections, each exported and imported on its own.
struct ImportExportView: View {
    let store: SnippetStore
    let connections: ConnectionStore
    @State private var kind = Kind.snippets

    private enum Kind { case snippets, connections }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: $kind) {
                Text("Snippets").tag(Kind.snippets)
                Text("Connections").tag(Kind.connections)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 12)
            switch kind {
            case .snippets: SnippetImportExport(store: store)
            case .connections: ConnectionImportExport(store: connections)
            }
        }
    }
}

/// Exports chosen groups to YAML, and imports YAML after confirming anything that can run things.
private struct SnippetImportExport: View {
    let store: SnippetStore
    /// Groups left out of the export; every group starts included.
    @State private var excluded: Set<SnippetGroup.ID> = []
    @State private var message: String?
    /// The decoded file, held until the user confirms it.
    @State private var incoming: SnippetLibrary?
    @State private var risky: [RiskyAction] = []
    @State private var conflicts: [String] = []
    @State private var confirmingRisky = false
    @State private var resolvingConflicts = false

    var body: some View {
        Form {
            Section("Export") {
                ForEach(store.library.groups) { group in
                    Toggle(group.name.isEmpty ? "Untitled" : group.name, isOn: Binding(
                        get: { !excluded.contains(group.id) },
                        set: { if $0 { excluded.remove(group.id) } else { excluded.insert(group.id) } }))
                }
                Button("Export…", action: export)
                    .disabled(store.library.groups.allSatisfy { excluded.contains($0.id) })
            }
            Section("Import") {
                Button("Import…", action: chooseImport).disabled(store.loadError != nil)
                if store.loadError != nil {
                    Text("Fix snippets.yaml before importing.").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 320)
        .sheet(isPresented: $confirmingRisky) {
            RiskyActionsSheet(actions: risky, cancel: cancelImport) {
                confirmingRisky = false
                checkConflicts()
            }
        }
        .alert(conflicts.count == 1 ? "1 keyword already exists" : "\(conflicts.count) keywords already exist",
               isPresented: $resolvingConflicts) {
            Button("Skip") { merge(.skip) }
            Button("Replace") { merge(.replace) }
            Button("Cancel", role: .cancel, action: cancelImport)
        } message: {
            Text("Skip keeps your snippets; Replace uses the imported ones.\n" + conflicts.joined(separator: ", "))
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.yaml]
        panel.nameFieldStringValue = "snippets.yaml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let groups = Set(store.library.groups.map(\.id)).subtracting(excluded)
        do {
            try Data(LibraryImport.export(store.library, groups: groups).utf8).write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let library: SnippetLibrary
        do {
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                message = "\(url.lastPathComponent) isn't UTF-8 text."
                return
            }
            library = try SnippetYAML.decode(text)
        } catch {
            message = "Couldn't import \(url.lastPathComponent): \(error)"
            return
        }
        incoming = library
        risky = LibraryImport.riskyActions(in: library)
        // Nothing is merged until anything that can run things is confirmed.
        if risky.isEmpty { checkConflicts() } else { confirmingRisky = true }
    }

    private func checkConflicts() {
        guard let incoming else { return }
        conflicts = LibraryImport.conflicts(incoming: incoming, existing: store.library)
        if conflicts.isEmpty { merge(.skip) } else { resolvingConflicts = true }
    }

    private func merge(_ choice: ConflictChoice) {
        guard let incoming else { return }
        self.incoming = nil
        do {
            try store.update { $0 = LibraryImport.merge(incoming, into: $0, choice: choice) }
            message = "Imported."
        } catch {
            message = error.message
        }
    }

    private func cancelImport() {
        incoming = nil
        confirmingRisky = false
        message = "Nothing was imported."
    }
}

/// Lists what imported snippets would run, before any of them are imported.
private struct RiskyActionsSheet: View {
    let actions: [RiskyAction]
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("These snippets can run things on this Mac").font(.headline)
            Table(actions.indices.map { IndexedAction(index: $0, action: actions[$0]) }) {
                TableColumn("Name", value: \.action.snippetName)
                TableColumn("Keyword", value: \.action.keyword)
                TableColumn("Kind", value: \.kind)
                TableColumn("Target", value: \.action.target)
            }
            .frame(minHeight: 160)
            HStack {
                Spacer()
                // No default button, so Return doesn't import scripts by accident.
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Import", action: confirm)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private struct IndexedAction: Identifiable {
        let index: Int
        let action: RiskyAction
        var id: Int { index }
        var kind: String {
            switch action.kind {
            case .shell: "Script"
            case .openApp: "Open app"
            case .runShortcut: "Shortcut"
            case .shortcut: "Sends shortcut"
            }
        }
    }
}

/// Exports chosen folders to YAML, and imports YAML after showing every connection it adds.
private struct ConnectionImportExport: View {
    let store: ConnectionStore
    /// Top-level folders left out of the export; every folder starts included.
    @State private var excluded: Set<ConnectionFolder.ID> = []
    @State private var message: String?
    /// The decoded file and the chosen conflict handling, held until the user confirms the preview.
    @State private var incoming: ConnectionLibrary?
    @State private var choice = ConflictChoice.skip
    @State private var conflicts: [String] = []
    @State private var resolvingConflicts = false
    @State private var preview: [ConnectionImport.PreviewRow]?

    var body: some View {
        Form {
            Section("Export") {
                ForEach(store.library.folders) { folder in
                    Toggle(folder.name.isEmpty ? "Untitled" : folder.name, isOn: Binding(
                        get: { !excluded.contains(folder.id) },
                        set: { if $0 { excluded.remove(folder.id) } else { excluded.insert(folder.id) } }))
                }
                Button("Export…", action: export)
                    .disabled(store.library.folders.allSatisfy { excluded.contains($0.id) })
            }
            Section("Import") {
                Button("Import…", action: chooseImport).disabled(store.loadError != nil)
                if store.loadError != nil {
                    Text("Fix connections.yaml before importing.").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 320)
        .alert(conflicts.count == 1 ? "1 activation string already exists" : "\(conflicts.count) activation strings already exist",
               isPresented: $resolvingConflicts) {
            Button("Skip") { showPreview(.skip) }
            Button("Replace") { showPreview(.replace) }
            Button("Cancel", role: .cancel, action: cancelImport)
        } message: {
            Text("Skip keeps your connections; Replace uses the imported ones.\n" + conflicts.joined(separator: ", "))
        }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            ConnectionPreviewSheet(rows: preview ?? [], cancel: cancelImport, confirm: merge)
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.yaml]
        panel.nameFieldStringValue = "connections.yaml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Everything chosen: the whole file, global credentials included.
        let folders = excluded.isEmpty ? nil : Set(store.library.folders.map(\.id)).subtracting(excluded)
        do {
            try Data(ConnectionImport.export(store.library, folders: folders).utf8).write(to: url, options: .atomic)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = "Couldn't export: \(error.localizedDescription)"
        }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let library: ConnectionLibrary
        do {
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                message = "\(url.lastPathComponent) isn't UTF-8 text."
                return
            }
            library = try ConnectionYAML.decode(text)
        } catch {
            message = "Couldn't import \(url.lastPathComponent): \(error)"
            return
        }
        incoming = library
        conflicts = ConnectionImport.conflicts(incoming: library, existing: store.library)
        if conflicts.isEmpty { showPreview(.skip) } else { resolvingConflicts = true }
    }

    /// Nothing is merged until the preview is confirmed.
    private func showPreview(_ choice: ConflictChoice) {
        guard let incoming else { return }
        self.choice = choice
        preview = ConnectionImport.previewRows(incoming: incoming, existing: store.library, choice: choice)
    }

    private func merge() {
        guard let incoming else { return }
        self.incoming = nil
        preview = nil
        do {
            try store.update { $0 = ConnectionImport.merge(incoming, into: $0, choice: choice) }
            message = "Imported."
        } catch {
            message = error.connectionsMessage
        }
    }

    private func cancelImport() {
        incoming = nil
        preview = nil
        message = "Nothing was imported."
    }
}

/// Lists every connection an import adds, with what runs on connect, before any of them are added.
private struct ConnectionPreviewSheet: View {
    let rows: [ConnectionImport.PreviewRow]
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("These connections will be added").font(.headline)
            if rows.isEmpty {
                Text("None: the file adds only folders.").foregroundStyle(.secondary)
            } else {
                // Blocks of wrapping text, not table cells, so a long or multi-line option is never cut off.
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ConnectionImport.visible(row.name)).bold()
                        Text(ConnectionImport.visible(row.address)).font(.body.monospaced())
                        if let jump = row.jumpHost { field("Jump host", jump) }
                        if !row.sshOptions.isEmpty { field("SSH options", row.sshOptions) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 240)
            }
            Text("SSH options and jump hosts run when you connect, so check them before importing.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                // No default button, so Return doesn't import by accident.
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Import", action: confirm)
            }
        }
        .padding(20)
        .frame(width: 680)
    }

    private func field(_ label: String, _ value: String) -> some View {
        (Text(label + ": ").foregroundStyle(.secondary) + Text(ConnectionImport.visible(value)).font(.body.monospaced()))
            .fixedSize(horizontal: false, vertical: true)
    }
}
