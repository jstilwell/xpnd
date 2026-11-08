import SwiftUI

/// A login or sudo slot on a folder or connection: the resolved credential and where it comes
/// from, with Choose…, Clear (only for the item's own override) and Refresh.
struct CredentialRow: View {
    let title: String
    let editing: ConnectionEditing
    let resolved: ResolvedCredential?
    let own: CredentialRef?
    let set: (CredentialRef?) -> Void
    @State private var choosing = false
    @State private var refreshing = false
    @State private var problem: String?

    var body: some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(EditorRules.summary(resolved)).textSelection(.enabled)
                HStack {
                    Button("Choose…") { choosing = true }
                    if own != nil { Button("Clear") { set(nil) } }
                    if let ref = resolved?.ref {
                        Button("Refresh") { refresh(ref) }.disabled(refreshing)
                            .help("Re-read the title, username and any public key from the password manager")
                    }
                }
                .controlSize(.small)
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            }
        }
        .sheet(isPresented: $choosing) {
            CredentialPickerSheet(editing: editing) { ref in
                problem = nil
                set(ref)
            }
        }
    }

    private func refresh(_ ref: CredentialRef) {
        refreshing = true
        Task {
            defer { refreshing = false }
            do throws(CredentialError) {
                try await editing.refresh(ref)
                problem = nil
            } catch {
                problem = error.message
            }
        }
    }
}

/// "Choose from 1Password…" (or the Keychain): a debounced search over the provider's items. Picking
/// an SSH Key item also saves its public key, so connecting needs no 1Password call for it.
struct CredentialPickerSheet: View {
    let editing: ConnectionEditing
    let pick: (CredentialRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var account: String?
    @State private var items: [CredentialItem]?
    @State private var selection: String?
    @State private var problem: String?
    /// The running pick (it can wait on Touch ID); cancelled when the sheet closes.
    @State private var picking: Task<Void, Never>?
    /// Keychain only: the New Password form is showing.
    @State private var adding = false

    var body: some View {
        if adding {
            NewKeychainPasswordForm(cancel: { adding = false }) { title, username, password in
                do throws(CredentialError) {
                    let item = try KeychainProvider().add(title: title, username: username, password: password)
                    guard let ref = try await editing.pick(item, account: KeychainProvider.id) else { return nil }
                    pick(ref)
                    dismiss()
                    return nil
                } catch {
                    return error.message
                }
            }
        } else {
            chooser
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading) {
            Text(editing.usesKeychain ? "Choose from the Keychain" : "Choose from 1Password").font(.headline)
            TextField("Search", text: $query, prompt: Text(editing.usesKeychain ? "Title or username" : "Title, vault or username"))
                .textFieldStyle(.roundedBorder)
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Group {
                if let items {
                    if items.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        List(items, id: \.id, selection: $selection) { row($0) }
                            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { _ in choose() }
                    }
                } else if problem == nil {
                    ProgressView()
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if picking != nil { ProgressView().controlSize(.small) }
                if editing.usesKeychain { Button("New Password…") { adding = true } }
                Spacer()
                Button("Cancel", role: .cancel) {
                    picking?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Choose", action: choose).keyboardShortcut(.defaultAction).disabled(selection == nil || picking != nil)
            }
        }
        .padding()
        .frame(width: 480, height: 420)
        .task(id: query) { await search() }
        // Cancel, Esc, or the sheet closing any other way.
        .onDisappear { picking?.cancel() }
    }

    private func row(_ item: CredentialItem) -> some View {
        HStack {
            Image(systemName: Self.symbol(item.category)).frame(width: 20)
            VStack(alignment: .leading) {
                Text(item.title)
                Text([item.vaultName, item.username].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(item.id)
    }

    private static func symbol(_ category: CredentialCategory) -> String {
        switch category {
        case .sshKey: "key"
        case .login: "person.crop.circle"
        case .password: "lock"
        case .server: "server.rack"
        }
    }

    /// `.task(id:)` cancels the previous search on each keystroke, so the sleep is the debounce.
    private func search() async {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        do throws(CredentialError) {
            let account: String
            if let known = self.account {
                account = known
            } else {
                account = try await editing.account()
                self.account = account
            }
            let found = try await editing.provider.search(query, account: account)
            guard !Task.isCancelled else { return }
            items = found
            problem = nil
        } catch {
            guard !Task.isCancelled else { return }
            items = nil
            problem = error.message
        }
    }

    private func choose() {
        guard let account, let item = items?.first(where: { $0.id == selection }), picking == nil else { return }
        picking = Task {
            defer { picking = nil }
            do throws(CredentialError) {
                guard let ref = try await editing.pick(item, account: account), !Task.isCancelled else { return }
                pick(ref)
                dismiss()
            } catch {
                if !Task.isCancelled { problem = error.message }
            }
        }
    }
}

/// A new login-keychain password: a title, an optional username, and the password.
private struct NewKeychainPasswordForm: View {
    let cancel: () -> Void
    /// Saves and picks it; returns a problem to show, or nil.
    let save: @MainActor (_ title: String, _ username: String, _ password: String) async -> String?
    @State private var title = ""
    @State private var username = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("New Keychain Password").font(.headline)
            Form {
                TextField("Title", text: $title)
                TextField("Username", text: $username, prompt: Text("Optional"))
                SecureField("Password", text: $password)
            }
            Text("Saved in your login keychain. Change or delete it later in Keychain Access.")
                .font(.callout).foregroundStyle(.secondary)
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    saving = true
                    Task {
                        problem = await save(title.trimmingCharacters(in: .whitespaces),
                                             username.trimmingCharacters(in: .whitespaces), password)
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
            }
        }
        .padding()
        .frame(width: 480, height: 420)
    }
}
