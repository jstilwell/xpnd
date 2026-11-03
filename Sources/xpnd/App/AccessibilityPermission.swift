import AppKit
import ApplicationServices
import Observation

/// Lets xpnd type: post the backspaces, Cmd+V, and keys of an expansion.
enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    /// Adds the app to the Accessibility list, switched off, so it's there to turn on (macOS may say so
    /// in an alert of its own the first time), and opens the list.
    static func openSettings() {
        // kAXTrustedCheckOptionPrompt, by its value: Swift 6 won't read the C global.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(settingsURL)
    }
}

/// Lets xpnd hear keystrokes, to notice a typed keyword.
enum InputMonitoringPermission {
    static var isGranted: Bool { CGPreflightListenEventAccess() }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    /// Adds the app to the Input Monitoring list (macOS may ask in an alert of its own), and opens the list.
    static func openSettings() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(settingsURL)
    }
}

/// Where the app is running from.
enum AppLocation {
    /// Run from the disk image, or from where macOS runs a downloaded app it hasn't seen moved
    /// (App Translocation): access granted there doesn't last, and updates can't install.
    static var isTemporary: Bool {
        let readOnly = (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return isTemporary(Bundle.main.bundlePath, onReadOnlyVolume: readOnly)
    }

    /// A disk image mounts read-only under /Volumes; a writable drive there is a fine place for apps.
    static func isTemporary(_ path: String, onReadOnlyVolume readOnly: Bool) -> Bool {
        path.contains("/AppTranslocation/") || (readOnly && path.hasPrefix("/Volumes/"))
    }
}

/// Follows whether this app has Accessibility and Input Monitoring access. macOS posts no
/// notification for Input Monitoring, so both are checked every second, even while granted, to
/// notice either being turned off; and whenever the system says the list of trusted apps changed.
@MainActor @Observable
final class PermissionWatcher {
    private(set) var accessibility: Bool
    private(set) var inputMonitoring: Bool
    var isGranted: Bool { accessibility && inputMonitoring }
    /// Called when either is turned on or off.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var listObserver: NSObjectProtocol?

    init(interval: TimeInterval = 1) {
        self.interval = interval
        accessibility = AccessibilityPermission.isGranted
        inputMonitoring = InputMonitoringPermission.isGranted
    }

    func start() {
        // Posted, undocumented, when any app is added to or removed from the Accessibility list.
        // Trust can take a moment to settle afterward.
        listObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self?.check()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        let ax = AccessibilityPermission.isGranted, im = InputMonitoringPermission.isGranted
        guard ax != accessibility || im != inputMonitoring else { return }
        accessibility = ax
        inputMonitoring = im
        onChange?()
    }
}
