import Foundation

protocol EvaluationContext: Sendable {
    var now: Date { get }
    var locale: Locale { get }
    var timeZone: TimeZone { get }
    func environment(_ name: String) -> String?
    func snippet(keyword: String) -> Snippet?
    func runScript(path: String, timeoutMs: Int) async throws(ExpansionError) -> String
    /// The full name of the person logged in.
    var fullName: String { get }
    func clipboardText() async -> String?
    /// The text selected in the front app; nil when there's none or it can't be read.
    func selectedText() async -> String?
    func askInputs(_ fields: [InputField]) async -> [String: String]?
}

/// One field of the input form. A label used twice is one field, of the kind it had first.
struct InputField: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case text(default: String)
        case choice([String])
        case multiline
    }

    let label: String
    let kind: Kind
}

/// Turns a snippet's template into play steps. Every value is computed here, before anything
/// on screen changes, so a failure throws instead of leaving a partial expansion.
enum Evaluator {
    static func evaluate(_ snippet: Snippet, context: some EvaluationContext) async throws(ExpansionError) -> [PlayStep] {
        let fields = try inputFields(snippet, context: context)
        var answers: [String: String] = [:]
        if !fields.isEmpty {
            guard let given = await context.askInputs(fields) else { throw .inputCancelled }
            answers = given
        }
        return finish(try await expand(snippet, context: context, answers: answers, stack: []))
    }

    private enum Item { case step(PlayStep), cursor }

    /// How deep snippets may include each other, and how many pieces (text runs and variables) one expansion may have.
    static let maxDepth = 16
    static let maxPieces = 10_000

    /// Pass 1: the input form's fields in order of first appearance, through included snippets. It walks the same tree
    /// pass 2 will, so it throws for a cycle or a tree too big before anything is evaluated.
    static func inputFields(_ snippet: Snippet, context: some EvaluationContext) throws(ExpansionError) -> [InputField] {
        var fields: [InputField] = []
        var budget = maxPieces
        try collectInputs(snippet, context: context, stack: [], into: &fields, budget: &budget)
        return fields
    }

    private static func collectInputs(
        _ snippet: Snippet, context: some EvaluationContext, stack: [String], into fields: inout [InputField], budget: inout Int
    ) throws(ExpansionError) {
        let stack = stack + [snippet.keyword]
        for token in Template.parse(snippet.text) {
            budget -= 1
            guard budget >= 0 else { throw .comboTooDeep }
            guard case let .variable(name, argument, _) = token, case .success(let variable) = Variable.parse(name: name, argument: argument)
            else { continue }
            func add(_ label: String, _ kind: InputField.Kind) {
                if !fields.contains(where: { $0.label == label }) { fields.append(InputField(label: label, kind: kind)) }
            }
            switch variable {
            case let .input(label, def): add(label, .text(default: def))
            case let .choice(label, options): add(label, .choice(options))
            case .longInput(let label): add(label, .multiline)
            case .snippet(let keyword, _):
                if stack.contains(keyword) { throw .comboCycle(keyword) }
                guard stack.count <= maxDepth else { throw .comboTooDeep }
                guard let nested = context.snippet(keyword: keyword) else { throw .missingCombo(keyword) }
                try collectInputs(nested, context: context, stack: stack, into: &fields, budget: &budget)
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
        case .clipboard(let t): return text(transform(await context.clipboardText() ?? "", t))
        case .selection(let t): return text(transform(await context.selectedText() ?? "", t))
        case .date(let shift):
            return shifted(context.now, by: shift, context).map { text(format($0, "", date: .short, time: .none, context)) }
        case .time(let shift):
            return shifted(context.now, by: shift, context).map { text(format($0, "", date: .none, time: .short, context)) }
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
        case .input(let label, _), .choice(let label, _), .longInput(let label):
            return text(answers[label] ?? "")
        case .uuid: return text(UUID().uuidString)
        case .fullName: return text(context.fullName)
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
        }
    }

    private static func transform(_ s: String, _ t: Variable.Transform?) -> String {
        switch t {
        case nil: s
        case .trim: s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .upper: s.uppercased()
        case .lower: s.lowercased()
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
