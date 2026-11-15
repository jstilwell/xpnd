import AppKit
import SwiftUI

/// A text field that saves once typing pauses, on Return, when it goes away, and at quit, not on every key: each
/// save encodes and rewrites the whole file, and a synced folder uploads each one. Give it the edited item's `.id`,
/// so text typed into one item is never saved into the next one shown in its place.
struct CommittingTextField: View {
    let title: String
    /// The saved value; a change from outside shows unless typing is waiting to be saved.
    let text: String
    var prompt: Text?
    let commit: (String) -> Void

    @State private var draft: String?
    @State private var pending: Task<Void, Never>?

    init(_ title: String, text: String, prompt: Text? = nil, commit: @escaping (String) -> Void) {
        self.title = title
        self.text = text
        self.prompt = prompt
        self.commit = commit
    }

    var body: some View {
        TextField(title, text: Binding(get: { draft ?? text }, set: edit), prompt: prompt)
            .onSubmit(flush)
            .onDisappear(perform: flush)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in flush() }
    }

    private func edit(_ new: String) {
        draft = new
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: TemplateTextView.Coordinator.saveDelay)
            if !Task.isCancelled { flush() }
        }
    }

    private func flush() {
        pending?.cancel()
        pending = nil
        guard let draft else { return }
        self.draft = nil
        if draft != text { commit(draft) }
    }
}
