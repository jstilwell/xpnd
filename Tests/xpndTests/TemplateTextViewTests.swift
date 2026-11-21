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

    /// Minor 7: text set from outside drops the text's own undo, never the window's Delete and Move undos.
    @Test func theTextHasItsOwnUndoManager() {
        let (textView, coordinator, _) = editor()
        let text = coordinator.undoManager(for: textView)
        #expect(text != nil)
        let window = NSWindow()
        #expect(text !== window.undoManager)
    }

    /// A view whose coordinator checks with `marks`.
    private func checkedEditor(_ marks: [TemplateMark]) -> (NSTextView, TemplateTextView.Coordinator) {
        let view = TemplateTextView(text: "", snippetID: UUID(), isEditable: true, controller: TemplateTextController(),
                                    check: { _ in marks }) { _ in true }
        let textView = NSTextView()
        textView.allowsUndo = true
        let coordinator = view.makeCoordinator()
        textView.delegate = coordinator
        return (textView, coordinator)
    }

    @Test func highlightColoursGoodAndUnderlinesBad() {
        let (textView, coordinator) = checkedEditor([
            TemplateMark(range: NSRange(location: 0, length: 7), problem: nil),
            TemplateMark(range: NSRange(location: 8, length: 7), problem: "Nope."),
        ])
        textView.string = "#{date} #{nope}"
        coordinator.highlight(textView)
        let storage = textView.textStorage!
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == TemplateTextView.variableColor)
        #expect(storage.attribute(.underlineStyle, at: 9, effectiveRange: nil) as? Int == NSUnderlineStyle.thick.rawValue)
        #expect(storage.attribute(.toolTip, at: 9, effectiveRange: nil) as? String == "Nope.")
        #expect(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
    }

    @Test func highlightDoesNotTouchUndo() {
        let (textView, coordinator) = checkedEditor([TemplateMark(range: NSRange(location: 0, length: 7), problem: "x")])
        textView.string = "#{date}"
        coordinator.highlight(textView)
        #expect(coordinator.undoManager(for: textView)?.canUndo == false)
    }

    @Test func typedTextAfterAVariableIsPlain() {
        let (textView, coordinator) = checkedEditor([])
        let blue: [NSAttributedString.Key: Any] = [.foregroundColor: TemplateTextView.variableColor, .underlineStyle: 2, .toolTip: "x"]
        let typing = coordinator.textView(textView, shouldChangeTypingAttributes: [:], toAttributes: blue)
        #expect(typing[.foregroundColor] as? NSColor == .textColor)
        #expect(typing[.underlineStyle] == nil && typing[.toolTip] == nil)
    }

    @Test func noHighlightDuringMarkedText() {
        let (textView, coordinator) = checkedEditor([TemplateMark(range: NSRange(location: 0, length: 7), problem: nil)])
        textView.string = "#{date}"
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 7, length: 0))
        coordinator.highlight(textView)
        #expect(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != TemplateTextView.variableColor)
    }
}
