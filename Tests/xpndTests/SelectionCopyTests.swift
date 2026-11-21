import AppKit
import Testing
@testable import xpnd

@MainActor @Suite struct SelectionCopyTests {
    private func board() -> NSPasteboard { NSPasteboard(name: .init("xpnd-test-\(UUID().uuidString)")) }

    @Test func selectionReadsWhatThePressCopied() async {
        let pb = board()
        pb.clearContents()
        pb.setString("old", forType: .string)
        let text = await SelectionCopy.read(on: pb) {
            pb.clearContents()
            pb.setString("picked", forType: .string)
        }
        #expect(text == "picked")
        #expect(pb.string(forType: .string) == "old")
    }

    @Test func selectionTimesOutAndRestores() async {
        let pb = board()
        pb.clearContents()
        pb.setString("old", forType: .string)
        let start = ContinuousClock.now
        let text = await SelectionCopy.read(on: pb, timeout: .milliseconds(100)) {}
        #expect(text == nil)
        #expect(ContinuousClock.now - start >= .milliseconds(100))
        #expect(pb.string(forType: .string) == "old")
    }

    @Test func selectionRestoresTheClipboardExactly() async {
        let pb = board()
        pb.clearContents()
        let a = NSPasteboardItem(), b = NSPasteboardItem()
        a.setString("one", forType: .string)
        a.setData(Data([1, 2]), forType: .init("com.example.a"))
        b.setString("two", forType: .string)
        b.setData(Data([3]), forType: .init("com.example.b"))
        pb.writeObjects([a, b])
        _ = await SelectionCopy.read(on: pb) {
            pb.clearContents()
            pb.setString("picked", forType: .string)
        }
        let items = pb.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.string(forType: .string) == "one" && items.first?.data(forType: .init("com.example.a")) == Data([1, 2]))
        #expect(items.last?.string(forType: .string) == "two" && items.last?.data(forType: .init("com.example.b")) == Data([3]))
    }
}
