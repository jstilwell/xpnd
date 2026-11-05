import SwiftUI
import xpndRDP

/// A certificate FreeRDP can't vouch for. A changed one is marked as a warning and Return doesn't trust it.
struct RDPCertificatePrompt: View {
    let certificate: XPRDPCertificate
    let answer: (Bool) -> Void

    private var changed: Bool { certificate.kind == .changed }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(changed ? "This certificate has changed" : "Trust this certificate?").font(.headline)
            } icon: {
                Image(systemName: changed ? "exclamationmark.triangle.fill" : "lock.shield")
                    .foregroundStyle(changed ? .yellow : .secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                row("Host", "\(certificate.host):\(certificate.port)")
                row("Subject", certificate.subject)
                row("Issuer", certificate.issuer)
                row("SHA-256", certificate.fingerprintSHA256, monospaced: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { answer(false) }.keyboardShortcut(.cancelAction)
                Button("Trust") { answer(true) }.keyboardShortcut(changed ? nil : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(monospaced ? .caption.monospaced() : nil).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// FreeRDP has no username or password (none in the credential, or the server rejected them). The
/// username and domain are prefilled and editable. Nothing is kept: the password field is cleared as the
/// answer goes to the session.
struct RDPPasswordPrompt: View {
    struct Login {
        var username: String
        var domain: String
        var password: String
    }

    let host: String
    let answer: (Login?) -> Void
    private let title: String
    @State private var username: String
    @State private var domain: String
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    init(user: String, domain: String, host: String, answer: @escaping (Login?) -> Void) {
        self.host = host
        self.answer = answer
        title = user.isEmpty ? "Password for \(host)" : "Password for \(user)@\(host)"
        _username = State(initialValue: user)
        _domain = State(initialValue: domain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form {
                TextField("Username", text: $username).focused($focus, equals: .username)
                TextField("Domain", text: $domain, prompt: Text("Optional"))
                SecureField("Password", text: $password).focused($focus, equals: .password).onSubmit(connect)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    password = ""
                    answer(nil)
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect).keyboardShortcut(.defaultAction).disabled(username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focus = username.isEmpty ? .username : .password }
    }

    private func connect() {
        guard !username.isEmpty else { return }
        let typed = Login(username: username, domain: domain, password: password)
        password = ""
        answer(typed)
    }
}
