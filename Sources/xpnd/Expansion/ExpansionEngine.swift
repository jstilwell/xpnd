import Foundation

/// Turns typed keys into expansions: matches the typing buffer against the library, evaluates the
/// snippet, then plays it. Only one expansion runs at a time. Never log the buffer or any text.
@MainActor final class ExpansionEngine {
    /// Tuning value: lets the keyword's last keystroke, which the listen-only tap sees before the
    /// target app does, land there before the backspaces that delete it.
    static let typedKeywordSettle: Duration = .milliseconds(20)

    var isEnabled = true
    private(set) var isExpanding = false
    private(set) var buffer = TypingBuffer()
    /// The expansion a typed keyword started, so tests can await it.
    private(set) var pendingExpansion: Task<Void, Never>?

    private let store: SnippetStore
    private let player: Player
    private let makeContext: @MainActor () -> any EvaluationContext
    private let notify: @MainActor (String) -> Void

    init(
        store: SnippetStore, player: Player,
        makeContext: @escaping @MainActor () -> any EvaluationContext,
        notify: @escaping @MainActor (String) -> Void
    ) {
        self.store = store
        self.player = player
        self.makeContext = makeContext
        self.notify = notify
    }

    /// `targetsXpnd`: the key goes to one of xpnd's own windows (Settings, the picker). Expanding
    /// there would edit xpnd's own fields, so it never does, and the buffer starts over.
    func handle(_ input: KeyInput, targetsXpnd: Bool = false) {
        guard !targetsXpnd else { return buffer.apply(.reset) }
        guard isEnabled, !isExpanding, store.loadError == nil else { return }
        buffer.apply(input)
        guard let snippet = Matcher.match(buffer.text, in: store.library.activeSnippets) else { return }
        buffer.apply(.reset)
        // Claimed now, so nothing typed before the task starts can begin a second expansion.
        isExpanding = true
        pendingExpansion = Task {
            try? await Task.sleep(for: Self.typedKeywordSettle)
            await run(snippet, deletingCharacters: snippet.keyword.count)
        }
    }

    func resetBuffer() {
        buffer.apply(.reset)
    }

    /// Does nothing while another expansion is in flight: its paste would capture this one's text as
    /// the clipboard to restore.
    func expand(_ snippet: Snippet, deletingCharacters: Int) async {
        guard !isExpanding else { return }
        isExpanding = true
        await run(snippet, deletingCharacters: deletingCharacters)
    }

    private func run(_ snippet: Snippet, deletingCharacters: Int) async {
        defer { isExpanding = false }
        do throws(ExpansionError) {
            // Evaluation fails before anything on screen changes, so the keyword stays.
            let steps = try await Evaluator.evaluate(snippet, context: makeContext())
            try await player.play(steps, deletingCharacters: deletingCharacters)
        } catch {
            notify(error.message)
        }
    }
}
