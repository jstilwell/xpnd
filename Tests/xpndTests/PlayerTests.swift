import AppKit
import Testing
@testable import xpnd

@MainActor private final class FakeSender: KeystrokeSending {
    var log: [String] = []
    func backspace(times: Int) async { log.append("bs \(times)") }
    func paste(_ text: String) async { log.append("paste \(text)") }
    func press(_ key: KeyName, times: Int) async { log.append("key \(key) x\(times)") }
    func press(_ combo: KeyCombo) async { log.append("combo") }
}

private struct FakeActions: ActionRunning {
    func openApp(path: String) async throws(ExpansionError) { throw .appNotFound(path: path) }
    func runShortcut(name: String) async throws(ExpansionError) {}
}

@MainActor @Suite struct PlayerTests {
    @Test func backspacesThenStepsInOrder() async throws {
        let sender = FakeSender()
        let combo = KeyCombo(command: true, option: false, control: false, shift: false, keyCode: 9)
        let steps: [PlayStep] = [.paste("a"), .key(.tab, count: 3), .delay(milliseconds: 1), .shortcut(combo),
                                 .runShortcut(name: "S"), .paste("b"), .moveLeft(1)]
        try await Player(sender: sender, actions: FakeActions()).play(steps, deletingCharacters: 4)
        #expect(sender.log == ["bs 4", "paste a", "key tab x3", "combo", "paste b", "key left x1"])
    }

    @Test func zeroDeletionSkipsBackspace() async throws {
        let sender = FakeSender()
        try await Player(sender: sender, actions: FakeActions()).play([.paste("a")], deletingCharacters: 0)
        #expect(sender.log == ["paste a"])
    }

    @Test func actionFailureStopsPlayback() async {
        let sender = FakeSender()
        let player = Player(sender: sender, actions: FakeActions())
        await #expect(throws: ExpansionError.appNotFound(path: "/X.app")) {
            try await player.play([.paste("a"), .openApp(path: "/X.app"), .paste("b")], deletingCharacters: 2)
        }
        #expect(sender.log == ["bs 2", "paste a"])
    }

    @Test func snapshotRestoresEveryType() throws {
        let pb = NSPasteboard(name: .init("xpnd-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
        let custom = NSPasteboard.PasteboardType("com.example.custom")
        let customBytes = Data([1, 2, 3, 0, 254])
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setData(png, forType: .png)
        item.setData(customBytes, forType: custom)
        pb.clearContents()
        #expect(pb.writeObjects([item]))

        let snapshot = PasteboardSnapshot.capture(pb)
        pb.clearContents()
        pb.setString("other", forType: .string)
        snapshot.restore(to: pb)

        let restored = try #require(pb.pasteboardItems?.first)
        #expect(pb.pasteboardItems?.count == 1)
        #expect(restored.string(forType: .string) == "hello")
        #expect(restored.data(forType: .png) == png)
        #expect(restored.data(forType: custom) == customBytes)
    }

    @Test func emptySnapshotRestoresToEmpty() {
        let pb = NSPasteboard(name: .init("xpnd-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let snapshot = PasteboardSnapshot.capture(pb)
        pb.setString("other", forType: .string)
        snapshot.restore(to: pb)
        #expect(pb.pasteboardItems?.isEmpty ?? true)
    }

    @Test func pasteRestoresOriginalClipboard() async {
        let pb = NSPasteboard(name: .init("xpnd-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        var pasted: String?
        await CGEventKeystrokeSender.paste("expanded", on: pb, settle: .zero) { pasted = pb.string(forType: .string) }
        #expect(pasted == "expanded")
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func pasteDoesNotRestoreOverNewerCopy() async {
        let pb = NSPasteboard(name: .init("xpnd-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        await CGEventKeystrokeSender.paste("expanded", on: pb, settle: .zero) {
            pb.clearContents()
            pb.setString("user copy", forType: .string)
        }
        #expect(pb.string(forType: .string) == "user copy")
    }
}
