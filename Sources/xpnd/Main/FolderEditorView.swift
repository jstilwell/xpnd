import SwiftUI

/// A folder's Details: name, activation string (derived, custom or none) and its credentials.
/// The global credentials live in Settings → Password manager.
struct FolderEditorView: View {
    let editing: ConnectionEditing
    let folder: ConnectionFolder
    /// A field the sidebar asked to focus; consumed here.
    @Binding var focus: EditorFocus?

    private enum Mode: Hashable { case derived, custom, none }
    private enum Field: Hashable { case name, mode, custom }

    @FocusState private var focused: Field?
    /// Custom stays chosen while its text is unsaved (it has a problem) or empty.
    @State private var customChosen = false
    @State private var customText = ""

    var body: some View {
        let namespace = editing.namespace
        let library = editing.library
        Form {
            TextField("Name", text: Binding(get: { folder.name }, set: { name in editing.edit(folder: folder.id) { $0.name = name } }))
                .focused($focused, equals: .name)
            ColorChoice(own: folder.color,
                        inherited: library.folderPath(of: folder.id).dropLast().last.flatMap { library.color(for: .folder($0.id)) }) { color in
                editing.edit(folder: folder.id) { $0.color = color }
            }
            Section("Activation") {
                Picker("Activation string", selection: Binding(get: { mode }, set: choose)) {
                    Text("Derived from the name").tag(Mode.derived)
                    Text("Custom").tag(Mode.custom)
                    Text("None").tag(Mode.none)
                }
                .focused($focused, equals: .mode)
                switch mode {
                case .derived:
                    let effective = namespace.effectiveActivation(ofFolder: folder.id)
                    LabeledContent("String", value: effective.string ?? "None")
                    if let reason = effective.reason {
                        Text("\(reason), so this folder has none. Choose Custom to set one.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .custom:
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("String", text: Binding(get: { customText }, set: editCustom), prompt: Text("None"))
                            .focused($focused, equals: .custom)
                        if let problem = customProblem(namespace) {
                            Text(problem).font(.callout).foregroundStyle(.red)
                        }
                    }
                case .none:
                    EmptyView()
                }
            }
            Section("Credentials") {
                CredentialRow(title: "Login", editing: editing, resolved: library.folderLoginCredential(for: folder.id),
                              own: folder.credential) { ref in editing.edit(folder: folder.id) { $0.credential = ref } }
                CredentialRow(title: "Sudo", editing: editing, resolved: library.folderSudoCredential(for: folder.id),
                              own: folder.sudoCredential) { ref in editing.edit(folder: folder.id) { $0.sudoCredential = ref } }
            }
        }
        .formStyle(.grouped)
        .disabled(editing.readOnly)
        .onAppear { customText = folder.activation ?? "" }
        .onChange(of: folder.activation) {
            // Our own saves match the field; anything else came from the file.
            guard !(customChosen && folder.activation == customText) else { return }
            customChosen = false
            customText = folder.activation ?? ""
        }
        .onChange(of: focus, initial: true) {
            guard let request = focus else { return }
            focus = nil
            let field: Field = request == .name ? .name : (mode == .custom ? .custom : .mode)
            // Best-effort: the next turn, once this view is in the window.
            Task { focused = field }
        }
    }

    private var mode: Mode {
        if customChosen { return .custom }
        return switch folder.activation {
        case nil: .derived
        case ""?: .none
        default: .custom
        }
    }

    /// Empty means none, which is always allowed.
    private func customProblem(_ namespace: KeywordNamespace) -> String? {
        customText.isEmpty ? nil : namespace.problem(customText, for: .folder(folder.id))
    }

    private func choose(_ new: Mode) {
        switch new {
        case .derived:
            customChosen = false
            editing.edit(folder: folder.id) { $0.activation = nil }
        case .none:
            customChosen = false
            editing.edit(folder: folder.id) { $0.activation = "" }
        case .custom:
            customChosen = true
            if customText.isEmpty { customText = ConnectionFolder.derivedActivation(for: folder.name) }
            saveCustom()
        }
    }

    private func editCustom(_ text: String) {
        customText = text
        customChosen = true
        saveCustom()
    }

    private func saveCustom() {
        guard customProblem(editing.namespace) == nil, folder.activation != customText else { return }
        let new = customText
        editing.edit(folder: folder.id) { $0.activation = new }
    }
}
