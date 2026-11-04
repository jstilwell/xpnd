import SwiftUI

/// 1Password's status, the account to search, an `op` path override, and the global credentials.
struct PasswordManagerSettingsView: View {
    @Bindable var settings: AppSettings
    let editing: ConnectionEditing
    /// nil while checking.
    @State private var status: ProviderStatus?
    @State private var path = ""
    @State private var pathProblem: String?
    @FocusState private var editingPath: Bool

    var body: some View {
        let library = editing.library
        Form {
            Section("1Password") {
                LabeledContent("Status") {
                    HStack {
                        statusText
                        Button(status == nil ? "Checking…" : "Refresh") { Task { await check() } }
                            .controlSize(.small).disabled(status == nil)
                    }
                }
                switch status {
                case .notInstalled?:
                    Text("Install the 1Password CLI (op), or enter where it is below.")
                        .font(.callout).foregroundStyle(.secondary)
                case .notSignedIn(let message)?:
                    Text(message).font(.callout).textSelection(.enabled)
                    Text("In 1Password → Settings → Developer, turn on “Integrate with 1Password CLI”. If it's already on, unlock 1Password and press Refresh.")
                        .font(.callout).foregroundStyle(.secondary)
                case .chooseAccount(let accounts)?:
                    Text("You have more than one 1Password account. Choose yours; xpnd never guesses.")
                        .font(.callout).foregroundStyle(.secondary)
                    accountPicker(accounts, selected: "")
                case .ready(let accounts)?:
                    accountPicker(accounts, selected: accounts.first { $0.id == settings.onePasswordAccount }?.id ?? accounts.first?.id ?? "")
                case nil:
                    EmptyView()
                }
                LabeledContent("op path") {
                    VStack(alignment: .trailing, spacing: 4) {
                        TextField("op path", text: $path, prompt: Text("/opt/homebrew/bin/op"))
                            .labelsHidden()
                            .focused($editingPath)
                            .onSubmit(savePath)
                            .onChange(of: editingPath) { if !editingPath { savePath() } }
                        if let pathProblem { Text(pathProblem).font(.callout).foregroundStyle(.red) }
                    }
                }
                Text("Leave empty to look in /opt/homebrew/bin and /usr/local/bin. It saves when you press Return or leave the field.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                CredentialRow(title: "Login", editing: editing,
                              resolved: library.credential.map { ResolvedCredential(ref: $0, source: .connection) },
                              own: library.credential) { ref in editing.save { $0.credential = ref; return true } }
                CredentialRow(title: "Sudo", editing: editing, resolved: Self.globalSudo(library),
                              own: library.sudoCredential) { ref in editing.save { $0.sudoCredential = ref; return true } }
                if let problem = editing.saveProblem ?? (editing.readOnly ? "Fix connections.yaml to change these." : nil) {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("Global credentials")
            } footer: {
                Text("Used by every folder and connection that doesn't set its own.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .disabled(editing.readOnly)
            Section("Other password managers") {
                LabeledContent("Bitwarden", value: "Coming later").disabled(true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { path = settings.onePasswordPath ?? "" }
        .onDisappear(perform: savePath)
        .task { await check() }
    }

    @ViewBuilder private var statusText: some View {
        switch status {
        case nil: ProgressView().controlSize(.small)
        case .notInstalled?: Label("1Password CLI not found", systemImage: "xmark.circle").foregroundStyle(.red)
        case .notSignedIn?: Label("Not signed in, or integration off", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        case .chooseAccount?: Label("Choose your account", systemImage: "person.crop.circle.badge.questionmark")
        case .ready?: Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
        }
    }

    /// Choosing re-checks, so the probe (and 1Password's approval prompt) is for that account.
    private func accountPicker(_ accounts: [ProviderAccount], selected: String) -> some View {
        Picker("Account", selection: Binding(get: { selected }, set: { id in
            settings.onePasswordAccount = id
            Task { await check() }
        })) {
            if selected.isEmpty { Text("Choose…").tag("") }
            ForEach(accounts, id: \.id) { Text($0.email).tag($0.id) }
        }
    }

    /// The sudo slot falls back to the global login credential when that has a password.
    private static func globalSudo(_ library: ConnectionLibrary) -> ResolvedCredential? {
        if let sudo = library.sudoCredential { return ResolvedCredential(ref: sudo, source: .connection) }
        return library.credential.flatMap { $0.hasPassword ? ResolvedCredential(ref: $0, source: .login) : nil }
    }

    private func check() async {
        status = nil
        status = await editing.provider.status(account: settings.onePasswordAccount)
    }

    private func savePath() {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || (trimmed.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: trimmed)) else {
            pathProblem = "There's no program at that path. Enter the full path to op."
            return
        }
        pathProblem = nil
        let new = trimmed.isEmpty ? nil : trimmed
        guard new != settings.onePasswordPath else { return }
        settings.onePasswordPath = new
        Task { await check() }
    }
}
