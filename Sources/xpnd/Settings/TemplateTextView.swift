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
    @Binding var text: String
    var isEditable: Bool
    let controller: TemplateTextController

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
        controller.textView = textView
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        controller.textView = textView
        if textView.string != text {
            // A different snippet, or a reload from disk: keep the caret where it still fits.
            let selection = textView.selectedRange()
            textView.string = text
            // Undo would otherwise put the previous snippet's text into this one.
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TemplateTextView

        init(parent: TemplateTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            // The save failed, so the binding still holds the saved text: show that, not the unsaved edit.
            if parent.text != textView.string { textView.string = parent.text }
        }
    }
}
