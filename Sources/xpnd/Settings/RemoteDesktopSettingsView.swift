import SwiftUI

/// The defaults every RDP connection starts from. Saves at once.
struct RemoteDesktopSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var confirmingClear = false
    @State private var clearProblem: String?

    var body: some View {
        Form {
            RDPFields(options: $settings.remoteDesktop.asOptions)
            Section("Drop folders") {
                Picker("Clear drop folders", selection: $settings.remoteDesktop.dropFolderCleanup) {
                    ForEach([DropFolderCleanup.never, .onDisconnect, .after7Days], id: \.self) { Text(RDPOptionLabels.label(for: $0)).tag($0) }
                }
                Text("The drop drive redirects one folder only; a connection's own File drop drive option overrides the default above.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear now…", role: .destructive) { confirmingClear = true }
                if let clearProblem { Text(clearProblem).font(.callout).foregroundStyle(.red) }
            }
        }
        .confirmationDialog("Clear every drop folder?", isPresented: $confirmingClear) {
            Button("Clear now", role: .destructive) {
                do { try RDPDropFolder.clearAll(); clearProblem = nil } catch { clearProblem = "Couldn't clear the drop folders." }
            }
        } message: {
            Text("This deletes every connection's drop folder, including files Windows saved there. It can't be undone.")
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
