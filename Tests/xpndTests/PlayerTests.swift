import AppKit
import Testing
@testable import xpnd

@MainActor private final class FakeSender: KeystrokeSending {
    var log: [String] = []
    func backspace(times: Int) async { log.append("bs \(times)") }
    func paste(_ text: String) async { log.append("paste \(text)") }
    func press(_ key: KeyName, times: Int) async { log.append("key \(key) x\(times)") }
    func press(_ combo: KeyCombo) async { log.append("combo") }
    func restoreClipboard() async { log.append("restore") }
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
        // The clipboard comes back before a delay or a Shortcut, which may read it, and at the end.
        #expect(sender.log == ["bs 4", "paste a", "key tab x3", "restore", "combo", "paste b", "key left x1", "restore"])
    }

    @Test func appendingTextGoesBeforeTheCursorMove() {
        #expect([PlayStep.paste("ab"), .moveLeft(1)].appendingText(" x") == [.paste("ab x"), .moveLeft(3)])
        #expect([PlayStep.paste("ab")].appendingText(" ") == [.paste("ab ")])
        #expect([PlayStep]().appendingText(" ") == [.paste(" ")])
        #expect([PlayStep.key(.tab, count: 1)].appendingText(" ") == [.key(.tab, count: 1), .paste(" ")])
    }

    @Test func endsInTextOnlyAfterTextOrTheCursor() {
        #expect([PlayStep]().endsInText)
        #expect([PlayStep.paste("a")].endsInText)
        #expect([PlayStep.paste("a"), .moveLeft(1)].endsInText)
        #expect(![PlayStep.paste("a"), .key(.enter, count: 1)].endsInText)
        #expect(![PlayStep.delay(milliseconds: 1)].endsInText)
    }

    @Test func tailIsDeletedAndTypedAfterTheText() async throws {
        let sender = FakeSender()
        try await Player(sender: sender, actions: FakeActions()).play([.paste("a")], deletingCharacters: 5) { (" xy", 2) }
        #expect(sender.log == ["bs 7", "paste a xy", "restore"])
    }

    @Test func keysBetweenPastesKeepOneCapture() async throws {
        let sender = FakeSender()
        let steps: [PlayStep] = [.paste("a"), .key(.tab, count: 1), .paste("b"), .runShortcut(name: "S"), .paste("c")]
        try await Player(sender: sender, actions: FakeActions()).play(steps, deletingCharacters: 0)
        #expect(sender.log == ["paste a", "key tab x1", "paste b", "restore", "paste c", "restore"])
    }

    /// A keyboard shortcut may be ⌘V or ⌘C, which must see the user's clipboard.
    @Test func clipboardComesBackBeforeAShortcut() async throws {
        let sender = FakeSender()
        let paste = KeyCombo(command: true, option: false, control: false, shift: false, keyCode: 9)
        try await Player(sender: sender, actions: FakeActions()).play([.paste("a"), .shortcut(paste), .paste("b")], deletingCharacters: 0)
        #expect(sender.log == ["paste a", "restore", "combo", "paste b", "restore"])
    }

    @Test func nilTailCancelsBeforeDeleting() async {
        let sender = FakeSender()
        await #expect(throws: ExpansionError.typedDuringExpansion) {
            try await Player(sender: sender, actions: FakeActions()).play([.paste("a")], deletingCharacters: 3) { nil }
        }
        #expect(sender.log.isEmpty)
    }

    @Test func nothingPastedNothingRestored() async throws {
        let sender = FakeSender()
        try await Player(sender: sender, actions: FakeActions()).play([.key(.tab, count: 1)], deletingCharacters: 0)
        #expect(sender.log == ["key tab x1"])
    }

    @Test func zeroDeletionSkipsBackspace() async throws {
        let sender = FakeSender()
        try await Player(sender: sender, actions: FakeActions()).play([.paste("a")], deletingCharacters: 0)
        #expect(sender.log == ["paste a", "restore"])
    }

    @Test func actionFailureStopsPlayback() async {
        let sender = FakeSender()
        let player = Player(sender: sender, actions: FakeActions())
        await #expect(throws: ExpansionError.appNotFound(path: "/X.app")) {
            try await player.play([.paste("a"), .openApp(path: "/X.app"), .paste("b")], deletingCharacters: 2)
        }
        #expect(sender.log == ["bs 2", "paste a", "restore"]) // restored though playback failed
    }

    /// "Nothing changes and your keyword stays where it is" (README): a typo'd Shortcut or app fails first.
    @Test func aMissingShortcutOrAppFailsBeforeAnythingIsDeleted() async {
        let sender = FakeSender()
        let names: @Sendable () async -> [String]? = { ["Real"] }
        let player = Player(sender: sender, actions: ActionRunner(launch: { _ in }, shortcutNames: names))
        await #expect(throws: ExpansionError.unknownShortcut("Typo")) {
            try await player.play([.paste("Hi "), .runShortcut(name: "Typo"), .paste("there")], deletingCharacters: 3)
        }
        await #expect(throws: ExpansionError.appNotFound(path: "/Nope.app")) {
            try await player.play([.paste("Hi "), .openApp(path: "/Nope.app")], deletingCharacters: 3)
        }
        #expect(sender.log.isEmpty)
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
        let snapshot = CGEventKeystrokeSender.setAside(pb)
        var pasted: String?
        let written = await CGEventKeystrokeSender.write("expanded", to: pb, floor: .zero, cap: .seconds(1), margin: .zero) {
            pasted = pb.string(forType: .string)
        }
        CGEventKeystrokeSender.restore(snapshot, ifStill: written, on: pb)
        #expect(pasted == "expanded")
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func pasteDoesNotRestoreOverNewerCopy() async {
        let pb = NSPasteboard(name: .init("xpnd-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        let snapshot = CGEventKeystrokeSender.setAside(pb)
        let written = await CGEventKeystrokeSender.write("expanded", to: pb, floor: .zero, cap: .milliseconds(50), margin: .zero) {
            pb.clearContents()
            pb.setString("user copy", forType: .string)
        }
        CGEventKeystrokeSender.restore(snapshot, ifStill: written, on: pb)
        #expect(pb.string(forType: .string) == "user copy")
    }

    @Test func writeWaitsForTheCapWhenNothingReads() async {
        let pb = NSPasteboard(name: .init("xpnd-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        let start = ContinuousClock.now
        _ = await CGEventKeystrokeSender.write("x", to: pb, floor: .milliseconds(10), cap: .milliseconds(150), margin: .zero) {}
        #expect(ContinuousClock.now - start >= .milliseconds(150))
    }

    @Test func writeReturnsSoonAfterTheAppReads() async {
        let pb = NSPasteboard(name: .init("xpnd-test-\(UUID())"))
        defer { pb.releaseGlobally() }
        let start = ContinuousClock.now
        _ = await CGEventKeystrokeSender.write("x", to: pb, floor: .milliseconds(10), cap: .seconds(2), margin: .milliseconds(10)) {
            _ = pb.string(forType: .string)
        }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
}
