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
                            .help("Re-read the title, username and any public key from 1Password")
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

/// "Choose from 1Password…": a debounced search over the provider's items. Picking an SSH Key
/// item also saves its public key, so connecting needs no 1Password call for it.
struct CredentialPickerSheet: View {
    let editing: ConnectionEditing
    let pick: (CredentialRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var account: String?
    @State private var items: [CredentialItem]?
    @State private var selection: String?
    @State private var problem: String?
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Choose from 1Password").font(.headline)
            TextField("Search", text: $query, prompt: Text("Title, vault or username"))
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
                if picking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose", action: choose).keyboardShortcut(.defaultAction).disabled(selection == nil || picking)
            }
        }
        .padding()
        .frame(width: 480, height: 420)
        .task(id: query) { await search() }
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
        guard let account, let item = items?.first(where: { $0.id == selection }), !picking else { return }
        // Refs end up in argv and, for keys, a file name.
        guard CredentialRef.isSafe(item.id), CredentialRef.isSafe(item.vaultID) else {
            problem = CredentialError.invalidRef.message
            return
        }
        let ref = item.ref(account: account)
        picking = true
        Task {
            defer { picking = false }
            if ref.category == .sshKey {
                do throws(CredentialError) {
                    try await editing.savePublicKey(for: ref)
                } catch {
                    problem = error.message
                    return
                }
            }
            pick(ref)
            dismiss()
        }
    }
}
