import AppKit
import Testing
@testable import xpnd

/// When a snippet's text is saved as it is typed.
@MainActor struct TemplateTextViewTests {
    /// A text view with a coordinator that records each save.
    private func editor() -> (NSTextView, TemplateTextView.Coordinator, () -> [String]) {
        final class Saves { var all: [String] = [] }
        let saves = Saves()
        let view = TemplateTextView(text: "", snippetID: UUID(), isEditable: true, controller: TemplateTextController()) {
            saves.all.append($0)
            return true
        }
        let textView = NSTextView()
        let coordinator = view.makeCoordinator()
        return (textView, coordinator, { saves.all })
    }

    private func type(_ text: String, in textView: NSTextView, _ coordinator: TemplateTextView.Coordinator) {
        textView.string = text
        coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: textView))
    }

    /// Each save encodes and rewrites the whole library, so keys typed in a run are saved together.
    @Test func typingSavesOnceAfterAPause() async throws {
        let (textView, coordinator, saves) = editor()
        for text in ["H", "He", "Hel"] { type(text, in: textView, coordinator) }
        #expect(saves().isEmpty)
        #expect(coordinator.hasUnsavedText)
        // Polled: another suite can hold the main thread past any one fixed wait.
        for _ in 0..<200 where saves().isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(saves() == ["Hel"])
        #expect(!coordinator.hasUnsavedText)
    }

    /// Leaving the field, another snippet showing, and quitting can't wait for the pause.
    @Test func flushSavesAtOnceAndOnlyOnce() async throws {
        let (textView, coordinator, saves) = editor()
        type("Hello", in: textView, coordinator)
        coordinator.flush()
        #expect(saves() == ["Hello"])
        coordinator.flush()
        try await Task.sleep(for: TemplateTextView.Coordinator.saveDelay * 3)
        #expect(saves() == ["Hello"])
    }

    /// The view is reused for the next snippet: what was typed goes to the snippet it was typed in.
    @Test func whatWasTypedCanBeTakenForItsOwnSnippet() {
        let (textView, coordinator, saves) = editor()
        type("Hello", in: textView, coordinator)
        let pending = coordinator.takeUnsaved()
        #expect(pending?.text == "Hello")
        #expect(!coordinator.hasUnsavedText)
        #expect(saves().isEmpty)
        _ = pending?.save("Hello")
        #expect(saves() == ["Hello"])
        #expect(coordinator.takeUnsaved() == nil)
    }
}
