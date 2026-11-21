import Foundation

protocol EvaluationContext: Sendable {
    var now: Date { get }
    var locale: Locale { get }
    var timeZone: TimeZone { get }
    func clipboardText() async -> String?
    func environment(_ name: String) -> String?
    func snippet(keyword: String) -> Snippet?
    func runScript(path: String, timeoutMs: Int) async throws(ExpansionError) -> String
    func askInputs(_ labels: [String]) async -> [String: String]?
}

/// Turns a snippet's template into play steps. Every value is computed here, before anything
/// on screen changes, so a failure throws instead of leaving a partial expansion.
enum Evaluator {
    static func evaluate(_ snippet: Snippet, context: some EvaluationContext) async throws(ExpansionError) -> [PlayStep] {
        var labels: [String] = []
        var budget = maxPieces
        try collectInputs(snippet, context: context, stack: [], into: &labels, budget: &budget)
        var answers: [String: String] = [:]
        if !labels.isEmpty {
            guard let given = await context.askInputs(labels) else { throw .inputCancelled }
            answers = given
        }
        return finish(try await expand(snippet, context: context, answers: answers, stack: []))
    }

    private enum Item { case step(PlayStep), cursor }

    /// How deep snippets may include each other, and how many pieces (text runs and variables) one expansion may have.
    static let maxDepth = 16
    static let maxPieces = 10_000

    /// Pass 1: `#{input:}` labels in order of first appearance, through nested combos. It walks the same tree pass 2
    /// will, so it throws for a cycle or a tree too big before anything is evaluated.
    private static func collectInputs(
        _ snippet: Snippet, context: some EvaluationContext, stack: [String], into labels: inout [String], budget: inout Int
    ) throws(ExpansionError) {
        let stack = stack + [snippet.keyword]
        for token in Template.parse(snippet.text) {
            budget -= 1
            guard budget >= 0 else { throw .comboTooDeep }
            guard case let .variable(name, argument, _) = token, case .success(let variable) = Variable.parse(name: name, argument: argument)
            else { continue }
            switch variable {
            case .input(let label, _) where !labels.contains(label):
                labels.append(label)
            case .snippet(let keyword, _):
                if stack.contains(keyword) { throw .comboCycle(keyword) }
                guard stack.count <= maxDepth else { throw .comboTooDeep }
                guard let nested = context.snippet(keyword: keyword) else { throw .missingCombo(keyword) }
                try collectInputs(nested, context: context, stack: stack, into: &labels, budget: &budget)
            default:
                break
            }
        }
    }

    /// Pass 2: steps and cursor marks, unmerged. A variable that resolves to nil stays as its raw text.
    private static func expand(
        _ snippet: Snippet, context: some EvaluationContext, answers: [String: String], stack: [String]
    ) async throws(ExpansionError) -> [Item] {
        let stack = stack + [snippet.keyword]
        var items: [Item] = []
        for token in Template.parse(snippet.text) {
            switch token {
            case .text(let s):
                items.append(.step(.paste(s)))
            case let .variable(name, argument, raw):
                guard case .success(let variable) = Variable.parse(name: name, argument: argument) else {
                    items.append(.step(.paste(raw)))
                    continue
                }
                let resolved = try await resolve(variable, context: context, answers: answers, stack: stack)
                items += resolved ?? [.step(.paste(raw))]
            }
        }
        return items
    }

    private static func resolve(
        _ variable: Variable, context: some EvaluationContext, answers: [String: String], stack: [String]
    ) async throws(ExpansionError) -> [Item]? {
        func text(_ s: String) -> [Item] { [.step(.paste(s))] }
        func step(_ s: PlayStep) -> [Item] { [.step(s)] }

        switch variable {
        case .clipboard(nil): return text(await context.clipboardText() ?? "")
        case .date(nil): return text(format(context.now, "", date: .short, time: .none, context))
        case .time(nil): return text(format(context.now, "", date: .none, time: .short, context))
        case let .dateTime(shift, fmt):
            guard let date = shifted(context.now, by: shift, context) else { return nil }
            return text(format(date, fmt, date: .short, time: .short, context))
        case .cursor: return [.cursor]
        case let .snippet(keyword, c):
            if stack.contains(keyword) { throw .comboCycle(keyword) } // pass 1 throws first
            guard let nested = context.snippet(keyword: keyword) else { throw .missingCombo(keyword) }
            let items = try await expand(nested, context: context, answers: answers, stack: stack)
            guard c != .plain else { return items }
            return items.map {
                guard case .step(.paste(let s)) = $0 else { return $0 }
                return .step(.paste(c == .upper ? s.uppercased() : s.lowercased()))
            }
        case .input(let label, _):
            return text(answers[label] ?? "")
        case .envVar(let name):
            return text(context.environment(name) ?? "")
        case let .script(path, timeout):
            var out = try await context.runScript(path: path, timeoutMs: timeout ?? Variable.defaultScriptTimeoutMs)
            while out.last?.isNewline == true { out.removeLast() }
            return text(out)
        case let .key(key, count): return step(.key(key, count: count))
        case .shortcut(let s): return KeyCombo.parse(s).map { step(.shortcut($0)) }
        case .delay(let ms): return step(.delay(milliseconds: ms))
        case .openApp(let path): return step(.openApp(path: path))
        case .runShortcut(let name): return step(.runShortcut(name: name))
        default: return nil
        }
    }

    /// `date` moved by a shift spec on the Gregorian calendar; `date` itself for no shift.
    private static func shifted(_ date: Date, by spec: String?, _ context: some EvaluationContext) -> Date? {
        guard let spec else { return date }
        guard let steps = Variable.shiftSteps(spec) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        var date = date
        for (unit, n) in steps {
            guard let next = calendar.date(byAdding: unit, value: n, to: date) else { return nil }
            date = next
        }
        return date
    }

    /// An empty format means the given styles.
    private static func format(
        _ date: Date, _ format: String, date dateStyle: DateFormatter.Style, time timeStyle: DateFormatter.Style,
        _ context: some EvaluationContext
    ) -> String {
        let f = DateFormatter()
        f.locale = context.locale
        f.timeZone = context.timeZone
        if format.isEmpty {
            f.dateStyle = dateStyle
            f.timeStyle = timeStyle
        } else {
            f.dateFormat = format
        }
        return f.string(from: date)
    }

    /// Merges adjacent pastes, drops empty ones, and turns the first cursor into a left-arrow count.
    private static func finish(_ items: [Item]) -> [PlayStep] {
        var steps: [PlayStep] = []
        var seenCursor = false
        var charactersAfterCursor: Int?
        for item in items {
            switch item {
            case .cursor where !seenCursor:
                seenCursor = true
                charactersAfterCursor = 0
            case .cursor:
                break
            case .step(.paste(let s)):
                guard !s.isEmpty else { continue }
                charactersAfterCursor? += s.count
                if case .paste(let previous)? = steps.last {
                    steps[steps.count - 1] = .paste(previous + s)
                } else {
                    steps.append(.paste(s))
                }
            case .step(let s):
                // shortcut: the cursor is honoured only when nothing but text follows it; upgrade if
                // users need cursors before keys.
                charactersAfterCursor = nil
                steps.append(s)
            }
        }
        if let n = charactersAfterCursor, n > 0 { steps.append(.moveLeft(n)) }
        return steps
    }
}
