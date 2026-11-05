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

    var desktopText: String { desktopWidth > 0 ? "\(desktopWidth) × \(desktopHeight)" : "—" }
    var codecText: String { codec.isEmpty ? "—" : codec }
    var latencyText: String { latencyMs.map { "\($0) ms" } ?? "—" }
    var subjectText: String { certificateSubject ?? "—" }
    var fingerprintText: String { certificateFingerprint ?? "—" }
    var certificateNote: String? {
        certificateSubject == nil || certificateFingerprint == nil ? "Verified by a certificate authority, or not yet accepted" : nil
    }

    func connectedForText(at now: Date) -> String {
        guard let connectedSince else { return "—" }
        return Duration.seconds(max(0, now.timeIntervalSince(connectedSince))).formatted(.time(pattern: .hourMinuteSecond))
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
    /// Offers the files on the remote clipboard and, once Windows has them, clicks at `point` and sends Ctrl+V.
    /// `done` gets false when it was refused; then nothing is clicked or typed.
    func pasteFiles(_ urls: [URL], at point: CGPoint, done: @escaping (Bool) -> Void)
    func setClipboardSync(_ on: Bool)
    /// Reconnects this session with `changes` applied; never saved to the connection or Settings.
    func reconnect(with changes: (inout RDPSessionConfig) -> Void)
    func requestDisplay(_ display: RDPOptions.Display) -> Bool
    /// Ends the session as closing the tab does.
    func disconnect()
    func toggleFullScreen()
    func restoreFocus()
    func dropFolderCount() -> Int
    /// Off the main thread: a big file from a NAS would otherwise freeze every tab and snippet expansion.
    func copyIntoDropFolder(_ urls: [URL]) async throws -> RDPDropFolder.CopyResult
    func clearDropFolder() throws
    func revealDropFolder()
    /// False when it couldn't be saved.
    func saveDisplayAsDefault(_ display: RDPOptions.Display) -> Bool
}

/// The notch's state and actions. Audio, clipboard and display are this session's current values only;
/// every action hands the keyboard back to the desktop. Notices say counts, never file names.
@MainActor @Observable final class RDPNotchModel {
    var isPinned = false
    var isExpanded = false
    /// Pushed by the host on every change: the host isn't observable, and the buttons must follow it.
    var isConnected: Bool {
        didSet { if isConnected { displayRefused = false } }
    }
    private(set) var audio: RDPOptions.Audio
    private(set) var clipboardOn: Bool
    private(set) var display: RDPOptions.Display
    private(set) var dropCount = 0
    /// The server turned down the last display choice in this connection.
    private(set) var displayRefused = false
    var notice: String?

    /// Weak: the host owns the model (its drop handler calls in), so a strong reference would be a cycle.
    @ObservationIgnored private weak var actions: (any RDPNotchActions)?
    /// The latest desktop drop; only it may report a refusal, as a newer drop ends an older one.
    @ObservationIgnored private var latestPaste = 0
    /// The latest notch drop's copy. Internal for tests, which await it.
    @ObservationIgnored private(set) var copying: Task<Void, Never>?

    init(actions: any RDPNotchActions) {
        self.actions = actions
        isConnected = actions.isConnected
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
    var driveIsOn: Bool { actions?.config.driveDevice() != nil }
    /// What each drop target does, for the Files button's tooltip and popover.
    var dropHelp: String {
        let desktop = "Drop on the desktop to paste into the window there."
        return driveIsOn ? "\(desktop) Drop here to put files in the xpnd drive."
            : "The xpnd drive is off for this connection. \(desktop)"
    }

    func ctrlAltDel() { send(RDPKeySequence.ctrlAltDel) }
    func winR() { send(RDPKeySequence.winR) }
    func openDropFolderInExplorer() { send(RDPKeySequence.openDropFolder()) }

    func fullScreen() {
        actions?.toggleFullScreen()
        actions?.restoreFocus()
    }

    func chooseDisplay(_ choice: RDPOptions.Display) {
        if actions?.requestDisplay(choice) == true {
            display = choice
            displayRefused = false
        } else if actions?.isConnected == true {
            displayRefused = true
            notice = "The server fixed the desktop size."
        } else {
            notice = "Not connected"
        }
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
        } else {
            latestPaste += 1
            let paste = latestPaste
            notice = "Pasting \(Self.files(urls.count))…"
            actions?.pasteFiles(urls, at: point) { [weak self] accepted in
                if !accepted, self?.latestPaste == paste { self?.notice = "Couldn't paste the files." }
            }
        }
        actions?.restoreFocus()
    }

    /// True once the drop is accepted, which is what the drag waits for; the copy goes on after, and a closed tab
    /// only misses its notice. The host stays alive until the copy returns.
    @discardableResult func dropOnNotch(_ urls: [URL]) -> Bool {
        defer { actions?.restoreFocus() }
        guard let actions else { return false }
        guard actions.config.driveDevice() != nil else {
            notice = "The file drop drive is off for this connection."
            return false
        }
        guard !urls.isEmpty else {
            notice = "Nothing to copy."
            return false
        }
        notice = "Copying \(Self.files(urls.count))…"
        copying = Task { [weak self, weak actions] in
            do {
                guard let result = try await actions?.copyIntoDropFolder(urls) else { return }
                self?.noteCopied(result)
            } catch {
                self?.notice = "Couldn't copy into the xpnd drive."
            }
        }
        return true
    }

    /// Windows can save into the drive, so the count is read again when it's about to show.
    func refreshDropCount() { dropCount = actions?.dropFolderCount() ?? 0 }

    func revealDropFolder() {
        actions?.revealDropFolder()
        actions?.restoreFocus()
    }

    func clearDropFolder() {
        do { try actions?.clearDropFolder() } catch { notice = "Couldn't clear the drop folder." }
        dropCount = actions?.dropFolderCount() ?? 0
        actions?.restoreFocus()
    }

    func saveDisplayAsDefault() {
        notice = actions?.saveDisplayAsDefault(display) == true ? "Saved as this connection's default." : "Couldn't save the default display."
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

    func togglePin() {
        isPinned.toggle()
        if isPinned { isExpanded = true }
        actions?.restoreFocus()
    }

    func restoreFocus() { actions?.restoreFocus() }

    // MARK: Private

    private func noteCopied(_ result: RDPDropFolder.CopyResult) {
        refreshDropCount()
        let copied = result.names.isEmpty ? nil : "Copied \(Self.files(result.names.count)) into the xpnd drive"
        let n = result.failures.count
        let failed = n == 0 ? nil : "\(n) item\(n == 1 ? "" : "s") couldn't be copied (folders aren't supported)."
        notice = [copied.map { failed == nil ? $0 : $0 + "." }, failed].compactMap { $0 }.joined(separator: " ")
    }

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
