import AppKit
import SwiftUI

/// Lets the "Insert Variable" menu type at the template view's caret.
@MainActor
final class TemplateTextController {
    fileprivate weak var textView: NSTextView?

    /// Inserts at the caret, replacing any selection, as typing would (so it saves and can be undone).
    func insert(_ string: String) {
        guard let textView, textView.isEditable else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(string, replacementRange: textView.selectedRange())
    }
}

/// A plain-text, monospaced editor for snippet templates. SwiftUI's `TextEditor` can't expose the
/// caret on macOS 14, and its smart quotes, dashes, and substitutions would corrupt `#{…}` syntax.
struct TemplateTextView: NSViewRepresentable {
    /// The saved text. Typing doesn't go through a binding: `save` returns false when the store refused it.
    /// It runs once typing pauses (`Coordinator.saveDelay`), not per key.
    let text: String
    /// Which snippet this is, so switching snippets starts a fresh caret.
    let snippetID: Snippet.ID
    var isEditable: Bool
    let controller: TemplateTextController
    let save: (String) -> Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = context.coordinator
        textView.string = text
        context.coordinator.saved = text
        context.coordinator.shownID = snippetID
        controller.textView = textView
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let switched = coordinator.shownID != snippetID
        // What was typed belongs to the snippet it was typed in, whose `save` the old parent holds. Next turn
        // of the run loop: a save changes the store, which a view update may not do.
        if switched, let unsaved = coordinator.takeUnsaved() {
            Task { @MainActor in _ = unsaved.save(unsaved.text) }
        }
        coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        controller.textView = textView
        // Once typing is saved the text matches; only a switch or a change from outside differs. Never replace
        // text mid-composition (marked text from an input method), or typing that is still waiting to be saved.
        guard switched || (textView.string != text && !textView.hasMarkedText() && !coordinator.hasUnsavedText) else { return }
        coordinator.shownID = snippetID
        coordinator.replace(in: textView, with: text, caretAtStart: switched)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// The editor is going away (another kind of item selected, the window's content torn down).
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let unsaved = coordinator.takeUnsaved() {
            Task { @MainActor in _ = unsaved.save(unsaved.text) } // as in `updateNSView`
        }
        coordinator.stopWatchingForQuit()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TemplateTextView
        /// The text last saved (or shown from the store), to go back to if a save fails.
        var saved = ""
        var shownID: Snippet.ID?

        /// Tuning value: how long typing must pause before it is saved. Every save encodes and rewrites the
        /// whole library, and a synced folder uploads each one.
        static let saveDelay: Duration = .milliseconds(300)
        private var pendingSave: Task<Void, Never>?
        private weak var pendingView: NSTextView?
        private var quitObserver: (any NSObjectProtocol)?
        var hasUnsavedText: Bool { pendingSave != nil }

        init(parent: TemplateTextView) {
            self.parent = parent
            super.init()
            // Quitting inside the pause would lose the last keys.
            quitObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.flush() } }
        }

        func stopWatchingForQuit() {
            if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
            quitObserver = nil
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            pendingSave?.cancel()
            pendingView = textView
            pendingSave = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.saveDelay)
                if !Task.isCancelled { self?.flush() }
            }
        }

        /// Leaving the field can't wait for the pause.
        func textDidEndEditing(_ notification: Notification) { flush() }

        /// The typed text and the `save` of the snippet it was typed in, for a caller that saves it itself
        /// because this view is about to show another snippet; nil when everything is saved.
        func takeUnsaved() -> (text: String, save: (String) -> Bool)? {
            guard pendingSave != nil, let textView = pendingView else { return nil }
            pendingSave?.cancel()
            pendingSave = nil
            return (textView.string, parent.save)
        }

        /// Saves what was typed since the last save, now.
        func flush() {
            guard pendingSave != nil, let textView = pendingView else { return }
            pendingSave?.cancel()
            pendingSave = nil
            if parent.save(textView.string) {
                saved = textView.string
            } else {
                // The store kept the old text, so show that rather than the unsaved edit. Next turn of
                // the run loop, once the keystroke's undo group has closed.
                Task { @MainActor in self.replace(in: textView, with: self.saved, caretAtStart: false) }
            }
        }

        /// Text set from outside isn't on the undo stack, so undoing older edits would hit the wrong
        /// ranges: drop them.
        func replace(in textView: NSTextView, with text: String, caretAtStart: Bool) {
            let caret = caretAtStart ? 0 : min(textView.selectedRange().location, (text as NSString).length)
            textView.string = text
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            textView.undoManager?.removeAllActions()
            saved = text
        }
    }
}
