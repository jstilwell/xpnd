import AppKit
import Testing
@testable import xpnd

@MainActor struct SecretClipboardTests {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private func withBoard(_ body: (NSPasteboard) async -> Void) async {
        let board = NSPasteboard(name: .init("xpnd.test.\(UUID().uuidString)"))
        await body(board)
        board.releaseGlobally()
    }

    @Test func copiesWithMarkers() async {
        await withBoard { board in
            let task = SecretClipboard.copy("hunter2", to: board, clearAfter: .milliseconds(10))
            #expect(board.string(forType: .string) == "hunter2")
            let types = board.types ?? []
            #expect(types.contains(Self.concealed))
            #expect(types.contains(Self.transient))
            await task.value
        }
    }

    @Test func clearsWhenUnchanged() async {
        await withBoard { board in
            await SecretClipboard.copy("hunter2", to: board, clearAfter: .milliseconds(50)).value
            #expect(board.string(forType: .string) == nil)
        }
    }

    @Test func keepsNewerCopy() async {
        await withBoard { board in
            let task = SecretClipboard.copy("hunter2", to: board, clearAfter: .milliseconds(50))
            board.clearContents()
            board.setString("newer", forType: .string)
            await task.value
            #expect(board.string(forType: .string) == "newer")
        }
    }

    @Test func secondCopyKeepsItsOwnClock() async {
        await withBoard { board in
            let first = SecretClipboard.copy("one", to: board, clearAfter: .milliseconds(10))
            let second = SecretClipboard.copy("two", to: board, clearAfter: .milliseconds(500))
            await first.value
            #expect(board.string(forType: .string) == "two")
            await second.value
            #expect(board.string(forType: .string) == nil)
        }
    }
}
