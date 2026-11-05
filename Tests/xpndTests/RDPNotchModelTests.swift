import AppKit
import Observation
import SwiftUI
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
    var saveResult = true

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
    func saveDisplayAsDefault(_ display: RDPOptions.Display) -> Bool { calls.append("saveDisplayAsDefault"); return saveResult }
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

    @Test func connectionStateStartsFromTheHostAndIsObserved() {
        fake.isConnected = false
        let fresh = RDPNotchModel(actions: fake)
        #expect(!fresh.isConnected)
        nonisolated(unsafe) var changed = false
        withObservationTracking { _ = fresh.isConnected } onChange: { changed = true }
        fresh.isConnected = true
        #expect(changed)
    }

    @Test func aRefusedDisplayShowsAsFixedUntilAcceptedOrReconnected() {
        fake.displayResult = false
        model.chooseDisplay(.fit)
        #expect(model.displayRefused)
        fake.displayResult = true
        model.chooseDisplay(.fit)
        #expect(!model.displayRefused)

        fake.displayResult = false
        model.chooseDisplay(.fit)
        model.isConnected = false
        #expect(model.displayRefused)
        model.isConnected = true
        #expect(!model.displayRefused)
    }

    @Test func aDisplayChoiceWithNoSessionIsNotBlamedOnTheServer() {
        fake.isConnected = false
        fake.displayResult = false
        model.chooseDisplay(.fit)
        #expect(!model.displayRefused)
        #expect(model.notice == "Not connected")
    }

    @Test func pinningOpensTheRowAndUnpinningLeavesItToTheHover() {
        model.togglePin()
        #expect(model.isPinned && model.isExpanded)
        #expect(fake.calls == ["restoreFocus"])
        model.togglePin()
        #expect(!model.isPinned && model.isExpanded)
    }

    @Test func theDropCountCanBeRefreshed() {
        fake.dropCount = 4 // Windows saved into the drive
        model.refreshDropCount()
        #expect(model.dropCount == 4)
    }

    @Test func theDriveFollowsTheConnection() {
        #expect(model.driveIsOn)
        fake.config.dropDrive = false
        #expect(!model.driveIsOn)
    }

    @Test func aNotchDropReportsWhetherAnythingWasAccepted() {
        fake.copyResult = (["a"], [url])
        #expect(model.dropOnNotch([url, url]))
        fake.copyResult = ([], [url])
        #expect(!model.dropOnNotch([url]))
        fake.config.dropDrive = false
        #expect(!model.dropOnNotch([url]))
    }

    @Test func theDropHelpFollowsTheDrive() {
        #expect(model.dropHelp == "Drop on the desktop to paste into the window there. Drop here to put files in the xpnd drive.")
        fake.config.dropDrive = false
        #expect(model.dropHelp == "The xpnd drive is off for this connection. Drop on the desktop to paste into the window there.")
    }

    @Test func savingTheDefaultSaysHowItWent() {
        model.saveDisplayAsDefault()
        #expect(model.notice == "Saved as this connection's default.")
        fake.saveResult = false
        model.saveDisplayAsDefault()
        #expect(model.notice == "Couldn't save the default display.")
    }

    @Test func infoWordsForWhatIsUnknown() {
        let info = RDPConnectionInfo(XPRDPConnectionInfo())
        #expect(info.desktopText == "—")
        #expect(info.codecText == "—")
        #expect(info.latencyText == "—")
        #expect(info.connectedForText(at: Date()) == "—")
        #expect(info.subjectText == "—")
        #expect(info.fingerprintText == "—")
        #expect(info.certificateNote == "Verified by a certificate authority, or not yet accepted")
    }

    @Test func infoWordsForWhatIsKnown() {
        var info = RDPConnectionInfo(XPRDPConnectionInfo())
        info.desktopWidth = 1920
        info.desktopHeight = 1080
        info.codec = "RemoteFX"
        info.latencyMs = 12
        info.connectedSince = Date(timeIntervalSince1970: 0)
        info.certificateSubject = "CN=win"
        info.certificateFingerprint = "AA:BB"
        #expect(info.desktopText == "1920 × 1080")
        #expect(info.codecText == "RemoteFX")
        #expect(info.latencyText == "12 ms")
        #expect(info.connectedForText(at: Date(timeIntervalSince1970: 3725)) == "1:02:05")
        #expect(info.subjectText == "CN=win")
        #expect(info.fingerprintText == "AA:BB")
        #expect(info.certificateNote == nil)
        info.certificateFingerprint = nil
        #expect(info.certificateNote != nil)
    }

    @Test func disconnectAndFullScreenGoToTheHost() {
        model.fullScreen(); model.disconnect()
        #expect(fake.calls == ["toggleFullScreen", "restoreFocus", "disconnect", "restoreFocus"])
    }
}

/// The desktop under the notch: every click outside the notch's own frame must land here.
private struct Desktop: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor struct RDPNotchLayoutTests {
    private let fake = FakeNotchActions()

    @Test func theNotchIsOnlyTheHandleOrTheRow() {
        let model = RDPNotchModel(actions: fake)
        let handle = NSHostingView(rootView: RDPNotch(model: model)).fittingSize
        #expect(handle == NSSize(width: 56, height: 12))
        model.togglePin()
        let row = NSHostingView(rootView: RDPNotch(model: model)).fittingSize
        #expect(row.width < 360 && row.height < 40)
    }

    @Test func theDropTargetTakesFileDragsAndNoClicks() {
        let target = RDPFileDropTarget.DropView()
        #expect(target.registeredDraggedTypes == [.fileURL])
        #expect(target.hitTest(.zero) == nil)
    }

    @Test func clicksBesideTheNotchReachTheDesktop() async {
        for pinned in [false, true] {
            let model = RDPNotchModel(actions: fake)
            if pinned { model.togglePin() }
            let desktop = NSView()
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1000, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: Desktop(view: desktop).overlay(alignment: .top) { RDPNotch(model: model) })
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let frame = window.contentView!.superview!
            // SwiftUI places the desktop's view a moment later. Not a run-loop spin: that stalls other tests' timers.
            for _ in 0..<500 where frame.hitTest(NSPoint(x: 40, y: 635)) !== desktop { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(frame.hitTest(NSPoint(x: 500, y: 635)) === host, "pinned: \(pinned)") // the buttons, past the drop target
            #expect(frame.hitTest(NSPoint(x: 40, y: 635)) === desktop, "pinned: \(pinned)")
            #expect(frame.hitTest(NSPoint(x: 960, y: 635)) === desktop, "pinned: \(pinned)")
            #expect(frame.hitTest(NSPoint(x: 500, y: 320)) === desktop, "pinned: \(pinned)")
        }
    }
}
