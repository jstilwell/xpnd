import SwiftUI

/// The defaults every RDP connection starts from. Saves at once.
struct RemoteDesktopSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            RDPFields(options: $settings.remoteDesktop.asOptions)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
