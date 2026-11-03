import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Exports chosen groups to YAML, and imports YAML after confirming anything that can run things.
struct ImportExportView: View {
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
            }
        }
    }
}
