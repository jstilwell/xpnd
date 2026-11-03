import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Toggle("Expand keywords", isOn: $settings.expansionEnabled)
            LaunchAtLoginToggle()
            LabeledContent("Picker shortcut") {
                ShortcutRecorder(shortcut: $settings.pickerShortcut)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Registers the app as a login item. The system keeps this state, not UserDefaults.
private struct LaunchAtLoginToggle: View {
    @State private var isOn = SMAppService.mainApp.status == .enabled
    @State private var note: String?

    var body: some View {
        Toggle("Launch at login", isOn: Binding(get: { isOn }, set: update))
            // It can be changed in System Settings too, while this window stays open.
            .onAppear { isOn = SMAppService.mainApp.status == .enabled }
        if let note {
            Text(note).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func update(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            note = nil
        } catch {
            note = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        isOn = status == .enabled
        if status == .requiresApproval {
            note = "Allow xpnd in System Settings → General → Login Items."
        }
    }
}
