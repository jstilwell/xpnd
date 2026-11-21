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

    /// Puts `string` in place of `range`, as typing would, if the text there is still `expected` (it may have
    /// changed while a form was open).
    func replace(_ range: NSRange, expected: String, with string: String) {
        guard let textView, textView.isEditable, NSMaxRange(range) <= (textView.string as NSString).length,
              (textView.string as NSString).substring(with: range) == expected else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(string, replacementRange: range)
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
    /// Marks the variables in the text as it is now (not as saved, which lags the typing).
    var check: (String) -> [TemplateMark] = { _ in [] }
    /// Right-click → Edit Variable… on a variable that has a form: its range, its source text, and the variable.
    var editVariable: ((NSRange, String, Variable) -> Void)?
    let save: (String) -> Bool

    static let variableColor = NSColor.systemBlue
    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.font = Self.font
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
        context.coordinator.highlight(textView)
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
        // The library may have changed (an included snippet added or renamed).
        defer { coordinator.highlight(textView) }
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
        /// The text's own undo, so dropping it (`replace`) leaves the window's Delete and Move undos alone.
        private let textUndo = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { textUndo }

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
            highlight(textView)
            pendingSave?.cancel()
            pendingView = textView
            pendingSave = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.saveDelay)
                if !Task.isCancelled { self?.flush() }
            }
        }

        /// Colours good variables and underlines the ones that won't expand, with why as a tooltip. Attributes set on the
        /// storage directly register no undo. Skipped while an input method has marked text.
        func highlight(_ textView: NSTextView) {
            guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.underlineColor, range: full)
            storage.removeAttribute(.toolTip, range: full)
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: full)
            for mark in parent.check(textView.string) where NSMaxRange(mark.range) <= storage.length {
                if let problem = mark.problem {
                    storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: NSColor.systemRed,
                                           .toolTip: problem], range: mark.range)
                } else {
                    storage.addAttribute(.foregroundColor, value: TemplateTextView.variableColor, range: mark.range)
                }
            }
            storage.endEditing()
        }

        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            guard view.isEditable, parent.editVariable != nil, let found = Template.variable(at: charIndex, in: view.string),
                  VariableKind(found.variable) != nil else { return menu }
            let item = NSMenuItem(title: "Edit Variable…", action: #selector(editVariable(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = EditTarget(
                range: found.range, raw: (view.string as NSString).substring(with: found.range), variable: found.variable)
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
            return menu
        }

        @objc private func editVariable(_ sender: NSMenuItem) {
            guard let target = sender.representedObject as? EditTarget else { return }
            parent.editVariable?(target.range, target.raw, target.variable)
        }

        private final class EditTarget: NSObject {
            let range: NSRange
            let raw: String
            let variable: Variable
            init(range: NSRange, raw: String, variable: Variable) {
                self.range = range
                self.raw = raw
                self.variable = variable
            }
        }

        /// Typing next to a variable mustn't take its colour or underline.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var plain = newTypingAttributes
            plain[.foregroundColor] = NSColor.textColor
            plain[.underlineStyle] = nil
            plain[.underlineColor] = nil
            plain[.toolTip] = nil
            return plain
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
            highlight(textView)
        }
    }
}
