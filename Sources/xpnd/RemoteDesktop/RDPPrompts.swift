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

/// FreeRDP has no password (none in the credential, or the server asked again). Nothing is kept: the
/// field is cleared as the answer goes to the session.
struct RDPPasswordPrompt: View {
    let user: String
    let host: String
    let answer: (String?) -> Void
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(user.isEmpty ? "Password for \(host)" : "Password for \(user)@\(host)").font(.headline)
            Form {
                if !user.isEmpty { LabeledContent("Username", value: user) }
                SecureField("Password", text: $password).focused($focused).onSubmit(connect)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    password = ""
                    answer(nil)
                }
                .keyboardShortcut(.cancelAction)
                Button("Connect", action: connect).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func connect() {
        let typed = password
        password = ""
        answer(typed)
    }
}
