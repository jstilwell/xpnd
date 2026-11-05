import Foundation
import Testing
@testable import xpnd
import xpndRDP

@MainActor final class FakeNotchActions: RDPNotchActions {
    var isConnected = true
    var clipboardChannelLoaded = true
    var config = RDPOptions().resolved(over: .standard, host: "win", port: 3389, username: "me", domain: nil, dropFolder: "/tmp/xpnd-fake-drop")
    var info = RDPConnectionInfo(XPRDPConnectionInfo())
    var calls: [String] = []
    var sent: [[RDPKeyStep]] = []
    var pasteResult = true
    var displayResult = true
    var dropCount = 0
    var copyResult: (names: [String], failures: [URL]) = ([], [])
    var reconfigured: [RDPSessionConfig] = []

    func send(_ steps: [RDPKeyStep]) { calls.append("send"); sent.append(steps) }
    func pasteFiles(_ urls: [URL], at point: CGPoint) -> Bool { calls.append("pasteFiles"); return pasteResult }
    func setClipboardSync(_ on: Bool) { calls.append("setClipboardSync(\(on))") }
    func reconnect(with changes: (inout RDPSessionConfig) -> Void) {
        calls.append("reconnect")
        changes(&config)
        reconfigured.append(config)
    }
    func requestDisplay(_ display: RDPOptions.Display) -> Bool { calls.append("requestDisplay"); return displayResult }
    func disconnect() { calls.append("disconnect") }
    func toggleFullScreen() { calls.append("toggleFullScreen") }
    func restoreFocus() { calls.append("restoreFocus") }
    func dropFolderCount() -> Int { dropCount }
    func copyIntoDropFolder(_ urls: [URL]) throws -> (names: [String], failures: [URL]) {
        calls.append("copyIntoDropFolder"); return copyResult
    }
    func clearDropFolder() throws { calls.append("clearDropFolder"); dropCount = 0 }
    func revealDropFolder() { calls.append("revealDropFolder") }
    func saveDisplayAsDefault(_ display: RDPOptions.Display) { calls.append("saveDisplayAsDefault") }
}

@MainActor struct RDPNotchModelTests {
    private let fake = FakeNotchActions()
    private var model: RDPNotchModel { _model }
    private let _model: RDPNotchModel
    private let url = URL(fileURLWithPath: "/tmp/a.txt")

    init() { _model = RDPNotchModel(actions: fake) }

    @Test func everyActionRestoresFocus() {
        for connected in [true, false] {
            fake.isConnected = connected
            fake.calls = []
            let actions: [() -> Void] = [
                { model.ctrlAltDel() }, { model.winR() }, { model.fullScreen() }, { model.chooseDisplay(.fit) },
                { model.cycleAudio() }, { model.toggleClipboard() }, { model.dropOnDesktop([url], at: .zero) },
                { model.dropOnNotch([url]) }, { model.openDropFolderInExplorer() }, { model.revealDropFolder() },
                { model.clearDropFolder() }, { model.reconnect() }, { model.disconnect() }, { model.saveDisplayAsDefault() },
            ]
            for action in actions {
                let before = fake.calls.count
                action()
                #expect(fake.calls.last == "restoreFocus", "connected: \(connected)")
                #expect(fake.calls.count > before)
            }
        }
    }

    @Test func ctrlAltDelSendsCtrlAltEnd() {
        model.ctrlAltDel()
        #expect(fake.sent == [RDPKeySequence.ctrlAltDel])
        model.winR()
        #expect(fake.sent.last == RDPKeySequence.winR)
    }

    @Test func nothingIsSentWhenNotConnected() {
        fake.isConnected = false
        model.ctrlAltDel(); model.winR(); model.openDropFolderInExplorer()
        #expect(fake.sent.isEmpty)
        #expect(model.notice == "Not connected")
    }

    @Test func desktopDropPastesOnlyWhenConnected() {
        model.dropOnDesktop([url, url, url], at: CGPoint(x: 5, y: 6))
        #expect(fake.calls == ["pasteFiles", "restoreFocus"])
        #expect(model.notice == "Pasting 3 files…")
        model.dropOnDesktop([url], at: .zero)
        #expect(model.notice == "Pasting 1 file…")

        fake.calls = []
        fake.isConnected = false
        model.dropOnDesktop([url], at: .zero)
        #expect(fake.calls == ["restoreFocus"])
        #expect(model.notice == "Not connected")

        fake.isConnected = true
        model.toggleClipboard() // off
        fake.calls = []
        model.dropOnDesktop([url], at: .zero)
        #expect(fake.calls == ["restoreFocus"])
        #expect(model.notice == "Clipboard sync is off")
    }

    @Test func aRefusedPasteSaysSo() {
        fake.pasteResult = false
        model.dropOnDesktop([url], at: .zero)
        #expect(model.notice == "Couldn't paste the files.")
    }

    @Test func notchDropGoesToTheDrive() {
        fake.copyResult = (["a.txt", "b.txt"], [])
        fake.dropCount = 2
        model.dropOnNotch([url, url])
        #expect(fake.calls == ["copyIntoDropFolder", "restoreFocus"])
        #expect(model.dropCount == 2)
        #expect(model.lastDropNames == ["a.txt", "b.txt"])
        #expect(model.notice == "Copied 2 files into the xpnd drive")
    }

    @Test func notchDropNoticesCountSingularAndPluralAndNeverNames() {
        fake.copyResult = (["secret.txt"], [])
        model.dropOnNotch([url])
        #expect(model.notice == "Copied 1 file into the xpnd drive")
        fake.copyResult = (["a", "b"], [url])
        model.dropOnNotch([url])
        #expect(model.notice == "Copied 2 files into the xpnd drive. 1 item couldn't be copied (folders aren't supported).")
        fake.copyResult = (["a"], [url, url])
        model.dropOnNotch([url])
        #expect(model.notice == "Copied 1 file into the xpnd drive. 2 items couldn't be copied (folders aren't supported).")
        fake.copyResult = ([], [url])
        model.dropOnNotch([url])
        #expect(model.notice == "1 item couldn't be copied (folders aren't supported).")
        #expect(model.lastDropNames.isEmpty)
    }

    @Test func notchDropWithTheDriveOffCopiesNothing() {
        fake.config.dropDrive = false
        model.dropOnNotch([url])
        #expect(fake.calls == ["restoreFocus"])
        #expect(model.notice == "The file drop drive is off for this connection.")
        // The desktop still takes a drop: it uses the clipboard.
        model.dropOnDesktop([url], at: .zero)
        #expect(fake.calls.contains("pasteFiles"))
    }

    @Test func clearingTheDropFolderResetsTheCount() {
        fake.dropCount = 3
        model.clearDropFolder()
        #expect(model.dropCount == 0)
    }

    @Test func clipboardToggleReconnectsWhenChannelMissing() {
        model.toggleClipboard()
        #expect(!model.clipboardOn)
        #expect(fake.calls.first == "setClipboardSync(false)")
        #expect(model.clipboardButtonTitle == "Clipboard sync off")

        fake.calls = []
        model.toggleClipboard()
        #expect(model.clipboardOn)
        #expect(fake.calls == ["setClipboardSync(true)", "restoreFocus"])

        model.toggleClipboard()
        fake.clipboardChannelLoaded = false
        #expect(model.clipboardButtonTitle == "Reconnect to enable clipboard")
        fake.calls = []
        model.toggleClipboard()
        #expect(fake.calls == ["reconnect", "restoreFocus"])
        #expect(fake.config.clipboard)
        #expect(model.clipboardOn)
    }

    @Test func audioCycles() {
        fake.config.audio = .local
        let fresh = RDPNotchModel(actions: fake)
        fresh.cycleAudio(); #expect(fresh.audio == .remote); #expect(fake.config.audio == .remote)
        fresh.cycleAudio(); #expect(fresh.audio == .off); #expect(fake.config.audio == .off)
        fresh.cycleAudio(); #expect(fresh.audio == .local); #expect(fake.config.audio == .local)
    }

    @Test func aLiveDisplayChoiceSurvivesAnAudioOrClipboardReconnect() {
        let size = RDPOptions.Display.fixed(width: 1920, height: 1080)
        fake.config.display = .fit
        model.chooseDisplay(size)
        #expect(model.display == size)
        model.cycleAudio()
        #expect(fake.config.display == size)
        model.toggleClipboard() // off
        fake.clipboardChannelLoaded = false
        model.toggleClipboard() // on, needs reconnect
        #expect(fake.reconfigured.last?.display == size)
    }

    @Test func displayRefusedSetsNotice() {
        fake.displayResult = false
        let before = model.display
        model.chooseDisplay(.fixed(width: 1280, height: 720))
        #expect(model.notice == "The server fixed the desktop size.")
        #expect(model.display == before)
    }

    @Test func connectionInfoPassesEmptyCertificateFieldsAsNil() {
        let info = RDPConnectionInfo(XPRDPConnectionInfo())
        #expect(info.certificateSubject == nil)
        #expect(info.certificateFingerprint == nil)
        #expect(info.latencyMs == nil)
    }

    @Test func disconnectAndFullScreenGoToTheHost() {
        model.fullScreen(); model.disconnect()
        #expect(fake.calls == ["toggleFullScreen", "restoreFocus", "disconnect", "restoreFocus"])
    }
}
