import SwiftUI

/// A connection's Details. Every field saves at once; port and activation keep what's typed in
/// the field while it has a problem, and save once it's valid.
struct ConnectionEditorView: View {
    let editing: ConnectionEditing
    let connection: Connection
    /// A field the sidebar asked to focus; consumed here.
    @Binding var focus: EditorFocus?

    private enum JumpChoice: Hashable { case none, connection(Connection.ID), other }

    @FocusState private var focused: EditorFocus?
    @State private var portText = ""
    @State private var activationText = ""
    /// Other… stays chosen while its address is empty.
    @State private var otherChosen = false
    /// Why the last jump host picked was refused.
    @State private var jumpNote: String?

    var body: some View {
        let library = editing.library
        let namespace = editing.namespace
        let login = library.loginCredential(for: connection.id)
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: binding(\.name)).focused($focused, equals: .name)
                    Picker("Type", selection: binding(\.type)) {
                        Text("SSH").tag(ConnectionType.ssh)
                        Text("VNC").tag(ConnectionType.vnc)
                    }
                    TextField("Host", text: binding(\.host))
                    field(problem: EditorRules.parsePort(portText, type: connection.type).problem) {
                        TextField("Port", text: Binding(get: { portText }, set: editPort), prompt: Text(String(connection.type.defaultPort)))
                    }
                    TextField("Username", text: Binding(get: { connection.username ?? "" }, set: { name in
                        editing.edit(connection: connection.id) { $0.username = name.isEmpty ? nil : name }
                    }), prompt: Text(login?.ref.username ?? ""))
                    field(problem: activationProblem(namespace)) {
                        TextField("Activation string", text: Binding(get: { activationText }, set: editActivation), prompt: Text("None"))
                            .focused($focused, equals: .activation)
                    }
                }
                Section("Credentials") {
                    CredentialRow(title: "Login", editing: editing, resolved: login, own: connection.credential) { ref in
                        editing.edit(connection: connection.id) { $0.credential = ref }
                    }
                    CredentialRow(title: "Sudo", editing: editing, resolved: library.sudoCredential(for: connection.id),
                                  own: connection.sudoCredential) { ref in
                        editing.edit(connection: connection.id) { $0.sudoCredential = ref }
                    }
                }
                if connection.type == .ssh { advanced(library) }
            }
            .formStyle(.grouped)
            .disabled(editing.readOnly)
            HStack {
                Spacer()
                Button("Connect") { editing.connect(connection.id) }
            }
            .padding(8)
        }
        .onAppear {
            portText = connection.port.map(String.init) ?? ""
            activationText = connection.activation ?? ""
        }
        .onChange(of: connection.port) {
            // Our own saves match the field; anything else came from the file.
            let typed = EditorRules.parsePort(portText, type: connection.type)
            if typed.problem != nil || typed.port != connection.port { portText = connection.port.map(String.init) ?? "" }
        }
        .onChange(of: connection.activation) {
            if (connection.activation ?? "") != activationText { activationText = connection.activation ?? "" }
        }
        .onChange(of: focus, initial: true) {
            guard let request = focus else { return }
            focus = nil
            // Best-effort: the next turn, once this view is in the window.
            Task { focused = request }
        }
    }

    @ViewBuilder private func advanced(_ library: ConnectionLibrary) -> some View {
        let candidates = library.allConnections.filter { $0.type == .ssh && $0.id != connection.id }
        Section("Advanced") {
            field(problem: jumpNote ?? storedJumpProblem(library)) {
                Picker("Jump host", selection: Binding(get: { jumpChoice }, set: chooseJump)) {
                    Text("None").tag(JumpChoice.none)
                    ForEach(candidates) { Text($0.name).tag(JumpChoice.connection($0.id)) }
                    if case .connection(let id)? = connection.jumpHost, !candidates.contains(where: { $0.id == id }) {
                        Text("Missing connection").tag(JumpChoice.connection(id))
                    }
                    Divider()
                    Text("Other…").tag(JumpChoice.other)
                }
            }
            if jumpChoice == .other {
                TextField("Jump host address", text: Binding(get: {
                    if case .text(let text)? = connection.jumpHost { text } else { "" }
                }, set: { text in
                    otherChosen = true
                    editing.edit(connection: connection.id) { $0.jumpHost = text.isEmpty ? nil : .text(text) }
                }), prompt: Text("user@host:port"))
            }
            field(problem: (try? ShellQuote.split(connection.sshOptions)) == nil ? SSHCommandError.unbalancedQuote.message : nil) {
                TextField("SSH options", text: binding(\.sshOptions), prompt: Text("-o ServerAliveInterval=30"))
            }
            Toggle("Auto-sudo", isOn: binding(\.autoSudo))
        }
    }

    private func field(problem: String?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
        }
    }

    private func binding<T>(_ key: WritableKeyPath<Connection, T>) -> Binding<T> {
        Binding(get: { connection[keyPath: key] }, set: { value in editing.edit(connection: connection.id) { $0[keyPath: key] = value } })
    }

    private func editPort(_ text: String) {
        portText = text
        let typed = EditorRules.parsePort(text, type: connection.type)
        guard typed.problem == nil, typed.port != connection.port else { return }
        editing.edit(connection: connection.id) { $0.port = typed.port }
    }

    /// Empty means none, which is always allowed.
    private func activationProblem(_ namespace: KeywordNamespace) -> String? {
        activationText.isEmpty ? nil : namespace.problem(activationText, for: .connection(connection.id))
    }

    private func editActivation(_ text: String) {
        activationText = text
        let new = text.isEmpty ? nil : text
        guard activationProblem(editing.namespace) == nil, new != connection.activation else { return }
        editing.edit(connection: connection.id) { $0.activation = new }
    }

    private var jumpChoice: JumpChoice {
        switch connection.jumpHost {
        case .connection(let id)?: .connection(id)
        case .text?: .other
        case nil: otherChosen ? .other : .none
        }
    }

    /// A hand-edited jump host can be missing, keyless, or a loop.
    private func storedJumpProblem(_ library: ConnectionLibrary) -> String? {
        guard case .connection(let id)? = connection.jumpHost else { return nil }
        return EditorRules.jumpHostProblem(id, for: connection.id, in: library)
    }

    private func chooseJump(_ choice: JumpChoice) {
        switch choice {
        case .none:
            otherChosen = false
            jumpNote = nil
            editing.edit(connection: connection.id) { $0.jumpHost = nil }
        case .other:
            otherChosen = true
            jumpNote = nil
            if case .connection? = connection.jumpHost { editing.edit(connection: connection.id) { $0.jumpHost = nil } }
        case .connection(let id):
            // Refused choices aren't saved, so the picker shows the saved one again.
            if let problem = EditorRules.jumpHostProblem(id, for: connection.id, in: editing.library) {
                jumpNote = problem
                return
            }
            otherChosen = false
            jumpNote = nil
            editing.edit(connection: connection.id) { $0.jumpHost = .connection(id) }
        }
    }
}
