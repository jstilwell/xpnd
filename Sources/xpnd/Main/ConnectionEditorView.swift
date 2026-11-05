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
    /// The saved jump host's problem, worked out once per library change rather than per render.
    @State private var storedJumpProblem: String?

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
                        Text("RDP").tag(ConnectionType.rdp)
                    }
                    field(problem: connection.host.trimmingCharacters(in: .whitespaces).isEmpty ? "A host is required." : nil) {
                        TextField("Host", text: binding(\.host))
                    }
                    field(problem: EditorRules.parsePort(portText, type: connection.type).problem) {
                        TextField("Port", text: Binding(get: { portText }, set: editPort), prompt: Text(String(connection.type.defaultPort)))
                    }
                    TextField("Username", text: Binding(get: { connection.username ?? "" }, set: { name in
                        editing.edit(connection: connection.id) { $0.username = name.isEmpty ? nil : name }
                    }), prompt: Text(login?.ref.username ?? ""))
                    if connection.type == .rdp {
                        // A username like CORP\me or me@corp.local carries its domain, so the field would mislead.
                        if let carried = RDPLogin.carriedDomain(in: connection.username ?? login?.ref.username ?? "") {
                            LabeledContent("Domain") {
                                Text(carried.isEmpty ? "Part of the username" : carried).foregroundStyle(.secondary)
                            }
                        } else {
                            TextField("Domain", text: Binding(get: { connection.domain ?? "" }, set: { text in
                                editing.edit(connection: connection.id) { $0.domain = text.isEmpty ? nil : text }
                            }))
                        }
                    }
                    field(problem: activationProblem(namespace)) {
                        TextField("Activation string", text: Binding(get: { activationText }, set: editActivation), prompt: Text("None"))
                            .focused($focused, equals: .activation)
                    }
                    ColorChoice(own: connection.color,
                                inherited: library.path(of: connection.id).last.flatMap { library.color(for: .folder($0.id)) }) { color in
                        editing.edit(connection: connection.id) { $0.color = color }
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
                if connection.type == .rdp { rdpOptions }
            }
            .formStyle(.grouped)
            .disabled(editing.readOnly)
            HStack {
                Spacer()
                Button("Connect") { editing.connect(connection.id, false) }
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
        .onChange(of: editing.library, initial: true) {
            storedJumpProblem = Self.jumpProblem(of: connection.id, in: editing.library)
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

    private var rdpOptions: some View {
        Section {
            DisclosureGroup("RDP options") {
                Form {
                    RDPFields(options: Binding(get: { connection.rdp ?? RDPOptions() }, set: { options in
                        editing.edit(connection: connection.id) { $0.rdp = options }
                    }), defaults: AppSettings.shared.remoteDesktop)
                    gatewaySection
                }
                .formStyle(.grouped)
            }
        }
    }

    /// No host means no gateway; the credential falls back to the connection's own.
    private var gatewaySection: some View {
        let gateway = connection.rdp?.gateway
        return Section("Gateway") {
            TextField("Gateway host", text: Binding(get: { gateway?.host ?? "" }, set: { host in
                editing.edit(connection: connection.id) {
                    var options = $0.rdp ?? RDPOptions()
                    if host.isEmpty { options.gateway = nil } else if options.gateway == nil { options.gateway = .init(host: host) } else {
                        options.gateway?.host = host
                    }
                    $0.rdp = options
                }
            }), prompt: Text("None"))
            if let gateway {
                TextField("Gateway port", value: Binding(get: { gateway.port }, set: { port in
                    editing.edit(connection: connection.id) { $0.rdp?.gateway?.port = min(max(1, port), 65535) }
                }), format: .number.grouping(.never))
                CredentialRow(title: "Gateway login", editing: editing,
                              resolved: (gateway.credential ?? editing.library.loginCredential(for: connection.id)?.ref)
                                  .map { ResolvedCredential(ref: $0, source: .connection) },
                              own: gateway.credential) { ref in
                    editing.edit(connection: connection.id) { $0.rdp?.gateway?.credential = ref }
                }
            }
        }
    }

    @ViewBuilder private func advanced(_ library: ConnectionLibrary) -> some View {
        let candidates = library.allConnections.filter { $0.type == .ssh && $0.id != connection.id }
        Section("Advanced") {
            field(problem: jumpNote ?? storedJumpProblem) {
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
    private static func jumpProblem(of connection: Connection.ID, in library: ConnectionLibrary) -> String? {
        guard case .connection(let id)? = library.connection(connection)?.jumpHost else { return nil }
        return EditorRules.jumpHostProblem(id, for: connection, in: library)
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
