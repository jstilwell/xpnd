import Foundation
import Observation
import xpndRDP

/// What the notch shows in its Info popover; the session's `XPRDPConnectionInfo`, in Swift types.
struct RDPConnectionInfo: Equatable {
    var desktopWidth: Int
    var desktopHeight: Int
    var codec: String
    var latencyMs: Int?
    var connectedSince: Date?
    /// nil when the session has no certificate for the host (it reports "").
    var certificateSubject: String?
    var certificateFingerprint: String?
    var gatewayHost: String?

    init(_ info: XPRDPConnectionInfo) {
        desktopWidth = info.desktopWidth
        desktopHeight = info.desktopHeight
        codec = info.codec
        latencyMs = info.latencyMs?.intValue
        connectedSince = info.connectedSince
        certificateSubject = info.certificateSubject.isEmpty ? nil : info.certificateSubject
        certificateFingerprint = info.certificateFingerprint.isEmpty ? nil : info.certificateFingerprint
        gatewayHost = info.gatewayHost
    }
}

/// What the notch asks of the tab that owns the session (`RDPHost`); a fake stands in for it in tests.
@MainActor protocol RDPNotchActions: AnyObject {
    var isConnected: Bool { get }
    var clipboardChannelLoaded: Bool { get }
    var config: RDPSessionConfig { get }
    /// The session's current facts; read when the Info popover opens.
    var info: RDPConnectionInfo { get }
    /// Nothing unless connected.
    func send(_ steps: [RDPKeyStep])
    /// Offers the files on the remote clipboard, clicks at `point` and sends Ctrl+V; false when it couldn't.
    func pasteFiles(_ urls: [URL], at point: CGPoint) -> Bool
    func setClipboardSync(_ on: Bool)
    /// Reconnects this session with `changes` applied; never saved to the connection or Settings.
    func reconnect(with changes: (inout RDPSessionConfig) -> Void)
    func requestDisplay(_ display: RDPOptions.Display) -> Bool
    /// Ends the session as closing the tab does.
    func disconnect()
    func toggleFullScreen()
    func restoreFocus()
    func dropFolderCount() -> Int
    func copyIntoDropFolder(_ urls: [URL]) throws -> (names: [String], failures: [URL])
    func clearDropFolder() throws
    func revealDropFolder()
    func saveDisplayAsDefault(_ display: RDPOptions.Display)
}

/// The notch's state and actions. Audio, clipboard and display are this session's current values only;
/// every action hands the keyboard back to the desktop. Notices say counts, never file names.
@MainActor @Observable final class RDPNotchModel {
    var isPinned = false
    var isExpanded = false
    private(set) var audio: RDPOptions.Audio
    private(set) var clipboardOn: Bool
    private(set) var display: RDPOptions.Display
    private(set) var dropCount = 0
    private(set) var lastDropNames: [String] = []
    var notice: String?

    /// Weak: the host owns the model (its drop handler calls in), so a strong reference would be a cycle.
    @ObservationIgnored private weak var actions: (any RDPNotchActions)?

    init(actions: any RDPNotchActions) {
        self.actions = actions
        audio = actions.config.audio
        clipboardOn = actions.config.clipboard
        display = actions.config.display
        dropCount = actions.dropFolderCount()
    }

    var clipboardButtonTitle: String {
        if clipboardOn { return "Clipboard sync on" }
        return actions?.clipboardChannelLoaded == true ? "Clipboard sync off" : "Reconnect to enable clipboard"
    }

    var info: RDPConnectionInfo? { actions?.info }

    func ctrlAltDel() { send(RDPKeySequence.ctrlAltDel) }
    func winR() { send(RDPKeySequence.winR) }
    func openDropFolderInExplorer() { send(RDPKeySequence.openDropFolder()) }

    func fullScreen() {
        actions?.toggleFullScreen()
        actions?.restoreFocus()
    }

    func chooseDisplay(_ choice: RDPOptions.Display) {
        if actions?.requestDisplay(choice) == true { display = choice } else { notice = "The server fixed the desktop size." }
        actions?.restoreFocus()
    }

    func cycleAudio() {
        let next: RDPOptions.Audio = switch audio { case .local: .remote; case .remote: .off; case .off: .local }
        audio = next
        reconnectKeepingSession { $0.audio = next }
        actions?.restoreFocus()
    }

    func toggleClipboard() {
        if clipboardOn {
            clipboardOn = false
            actions?.setClipboardSync(false)
        } else {
            clipboardOn = true
            if actions?.clipboardChannelLoaded == true {
                actions?.setClipboardSync(true)
            } else {
                reconnectKeepingSession { $0.clipboard = true }
            }
        }
        actions?.restoreFocus()
    }

    func dropOnDesktop(_ urls: [URL], at point: CGPoint) {
        if actions?.isConnected != true {
            notice = "Not connected"
        } else if !clipboardOn {
            notice = "Clipboard sync is off"
        } else if actions?.pasteFiles(urls, at: point) == true {
            notice = "Pasting \(Self.files(urls.count))…"
        } else {
            notice = "Couldn't paste the files."
        }
        actions?.restoreFocus()
    }

    func dropOnNotch(_ urls: [URL]) {
        defer { actions?.restoreFocus() }
        guard let actions else { return }
        guard actions.config.driveDevice() != nil else {
            notice = "The file drop drive is off for this connection."
            return
        }
        do {
            let result = try actions.copyIntoDropFolder(urls)
            lastDropNames = result.names
            dropCount = actions.dropFolderCount()
            var parts: [String] = []
            if !result.names.isEmpty { parts.append("Copied \(Self.files(result.names.count)) into the xpnd drive") }
            if !result.failures.isEmpty {
                let n = result.failures.count
                parts.append("\(n) item\(n == 1 ? "" : "s") couldn't be copied (folders aren't supported)")
            }
            notice = parts.isEmpty ? "Nothing to copy." : parts.joined(separator: ". ") + (result.failures.isEmpty ? "" : ".")
        } catch {
            notice = "Couldn't copy into the xpnd drive."
        }
    }

    func revealDropFolder() {
        actions?.revealDropFolder()
        actions?.restoreFocus()
    }

    func clearDropFolder() {
        do { try actions?.clearDropFolder() } catch { notice = "Couldn't clear the drop folder." }
        dropCount = actions?.dropFolderCount() ?? 0
        lastDropNames = []
        actions?.restoreFocus()
    }

    func saveDisplayAsDefault() {
        actions?.saveDisplayAsDefault(display)
        actions?.restoreFocus()
    }

    func reconnect() {
        reconnectKeepingSession { _ in }
        actions?.restoreFocus()
    }

    func disconnect() {
        actions?.disconnect()
        actions?.restoreFocus()
    }

    // MARK: Private

    private func send(_ steps: [RDPKeyStep]) {
        if actions?.isConnected == true { actions?.send(steps) } else { notice = "Not connected" }
        actions?.restoreFocus()
    }

    /// A reconnect rebuilds the settings from the config, so the live display, audio and clipboard are put back first.
    private func reconnectKeepingSession(_ change: @escaping (inout RDPSessionConfig) -> Void) {
        let (audio, clipboard, display) = (audio, clipboardOn, display)
        actions?.reconnect { config in
            config.audio = audio
            config.clipboard = clipboard
            config.display = display
            change(&config)
        }
    }

    private static func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
}
