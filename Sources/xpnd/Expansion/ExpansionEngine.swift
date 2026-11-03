import Foundation

/// Turns typed keys into expansions: matches the typing buffer against the library, evaluates the
/// snippet, then plays it. An activation string instead deletes itself and hands off to `onActivate`.
/// Only one expansion or connection action runs at a time. Never log the buffer or any text.
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
    private let connections: ConnectionStore
    private let player: Player
    private let makeContext: @MainActor () -> any EvaluationContext
    private let notify: @MainActor (String) -> Void
    private let frontmostPID: @MainActor () -> pid_t?
    private let onActivate: @MainActor (ActivationTarget, pid_t?) async -> Void

    /// `KeywordNamespace`'s answers are too slow to work out per key inside the event tap's callback,
    /// so they're kept until either library changes.
    private var namespace = KeywordNamespace(snippets: .empty, connections: .empty)
    private var activations: [String: ActivationTarget] = [:]
    private var duplicates: Set<String> = []

    init(
        store: SnippetStore, connections: ConnectionStore, player: Player,
        makeContext: @escaping @MainActor () -> any EvaluationContext,
        notify: @escaping @MainActor (String) -> Void,
        frontmostPID: @escaping @MainActor () -> pid_t?,
        onActivate: @escaping @MainActor (ActivationTarget, pid_t?) async -> Void
    ) {
        self.store = store
        self.connections = connections
        self.player = player
        self.makeContext = makeContext
        self.notify = notify
        self.frontmostPID = frontmostPID
        self.onActivate = onActivate
    }

    /// `targetsXpnd`: the key goes to one of xpnd's own windows (Settings, the picker). Expanding
    /// there would edit xpnd's own fields, so it never does, and the buffer starts over.
    func handle(_ input: KeyInput, targetsXpnd: Bool = false) {
        guard !targetsXpnd else { return buffer.apply(.reset) }
        let snippetsOK = store.loadError == nil, connectionsOK = connections.loadError == nil
        // A dropped key breaks the run of typing, so a keyword can't span it. The in-flight expansion
        // doesn't read the buffer, so resetting it then is safe.
        guard isEnabled, !isExpanding, snippetsOK || connectionsOK else { return buffer.apply(.reset) }
        buffer.apply(input)
        refreshNamespace()
        let text = buffer.text
        let snippet = snippetsOK
            ? Matcher.match(text, in: store.library.activeSnippets.filter { !duplicates.contains($0.keyword) })
            : nil
        if connectionsOK, let target = activations[text], text.count > snippet?.keyword.count ?? 0 {
            start { await self.activate(target, deletingCharacters: text.count, in: $0) }
        } else if let snippet {
            start { await self.run(snippet, deletingCharacters: snippet.keyword.count, into: $0) }
        }
    }

    private func refreshNamespace() {
        guard namespace.snippets != store.library || namespace.connections != connections.library else { return }
        namespace = KeywordNamespace(snippets: store.library, connections: connections.library)
        activations = namespace.activations
        duplicates = namespace.crossFileDuplicates
    }

    /// `work` gets the app the string was typed in.
    private func start(_ work: @escaping @MainActor (pid_t?) async -> Void) {
        buffer.apply(.reset)
        // Claimed now, so nothing typed before the task starts can begin a second expansion.
        isExpanding = true
        let target = frontmostPID()
        pendingExpansion = Task {
            try? await Task.sleep(for: Self.typedKeywordSettle)
            await work(target)
        }
    }

    /// Runs `body` as the one action in flight, or returns false without running it if another is.
    func exclusive(_ body: @MainActor () async -> Void) async -> Bool {
        guard !isExpanding else { return false }
        isExpanding = true
        defer { isExpanding = false }
        await body()
        return true
    }

    func resetBuffer() {
        buffer.apply(.reset)
    }

    /// Does nothing while another expansion is in flight: its paste would capture this one's text as
    /// the clipboard to restore. Inserts into the app in front when called.
    func expand(_ snippet: Snippet, deletingCharacters: Int) async {
        guard !isExpanding else { return }
        isExpanding = true
        await run(snippet, deletingCharacters: deletingCharacters, into: frontmostPID())
    }

    /// `target`: the app the keyword was typed in. If another app is in front once evaluation ends
    /// (the user switched while the form was open or a script ran), nothing is deleted or pasted.
    private func run(_ snippet: Snippet, deletingCharacters: Int, into target: pid_t?) async {
        defer { isExpanding = false }
        do throws(ExpansionError) {
            // Evaluation fails before anything on screen changes, so the keyword stays.
            let steps = try await Evaluator.evaluate(snippet, context: makeContext())
            guard frontmostPID() == target else { throw .targetAppChanged }
            try await player.play(steps, deletingCharacters: deletingCharacters)
        } catch {
            notify(error.message)
        }
    }

    /// `target`: the app the string was typed in. It must stay in front through the delete, so
    /// nothing is removed from, or connected relative to, the wrong app.
    private func activate(_ action: ActivationTarget, deletingCharacters: Int, in target: pid_t?) async {
        defer { isExpanding = false }
        do throws(ExpansionError) {
            guard frontmostPID() == target else { throw .targetAppChanged }
            try await player.play([], deletingCharacters: deletingCharacters)
            guard frontmostPID() == target else { throw .targetAppChanged }
            await onActivate(action, target)
        } catch {
            notify(error.message)
        }
    }
}
