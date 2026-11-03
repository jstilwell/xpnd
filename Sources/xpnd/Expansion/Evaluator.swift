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
        try collectInputs(snippet, context: context, stack: [], into: &labels)
        var answers: [String: String] = [:]
        if !labels.isEmpty {
            guard let given = await context.askInputs(labels) else { throw .inputCancelled }
            answers = given
        }
        return finish(try await expand(snippet, context: context, answers: answers, stack: []))
    }

    private enum Item { case step(PlayStep), cursor }

    /// Pass 1: `#{input:}` labels in order of first appearance, through nested combos.
    private static func collectInputs(
        _ snippet: Snippet, context: some EvaluationContext, stack: [String], into labels: inout [String]
    ) throws(ExpansionError) {
        let stack = stack + [snippet.keyword]
        for case let .variable(name, argument?, _) in Template.parse(snippet.text) where !argument.isEmpty {
            switch name {
            case "input" where !labels.contains(argument):
                labels.append(argument)
            case "combo", "upper", "lower":
                if stack.contains(argument) { continue }
                guard let nested = context.snippet(keyword: argument) else { throw .missingCombo(argument) }
                try collectInputs(nested, context: context, stack: stack, into: &labels)
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
                let resolved = try await resolve(name, argument, context: context, answers: answers, stack: stack)
                items += resolved ?? [.step(.paste(raw))]
            }
        }
        return items
    }

    private static func resolve(
        _ name: String, _ argument: String?, context: some EvaluationContext, answers: [String: String], stack: [String]
    ) async throws(ExpansionError) -> [Item]? {
        func text(_ s: String) -> [Item] { [.step(.paste(s))] }
        func step(_ s: PlayStep) -> [Item] { [.step(s)] }

        guard let arg = argument else {
            switch name {
            case "clipboard": return text(await context.clipboardText() ?? "")
            case "date": return text(format(context.now, "", date: .short, time: .none, context))
            case "time": return text(format(context.now, "", date: .none, time: .short, context))
            case "dateTime": return text(format(context.now, "", date: .short, time: .short, context))
            case "cursor": return [.cursor]
            default: return nil
            }
        }
        guard !arg.isEmpty else { return nil }
        switch name {
        case "dateTime":
            return dateTime(arg, context).map(text)
        case "combo", "upper", "lower":
            if stack.contains(arg) { return nil }  // a cycle stays literal
            guard let nested = context.snippet(keyword: arg) else { throw .missingCombo(arg) }
            let items = try await expand(nested, context: context, answers: answers, stack: stack)
            guard name != "combo" else { return items }
            return items.map {
                guard case .step(.paste(let s)) = $0 else { return $0 }
                return .step(.paste(name == "upper" ? s.uppercased() : s.lowercased()))
            }
        case "input":
            return text(answers[arg] ?? "")
        case "envVar":
            return text(context.environment(arg) ?? "")
        case "shell":
            var path = arg, timeout = 10000
            if let colon = arg.lastIndex(of: ":"), case let digits = arg[arg.index(after: colon)...],
               isDigits(digits) {
                guard let t = Int(digits) else { return nil }
                path = String(arg[..<colon])
                timeout = t
            }
            guard !path.isEmpty else { return nil }
            var out = try await context.runScript(path: path, timeoutMs: timeout)
            while out.last?.isNewline == true { out.removeLast() }
            return text(out)
        case "key":
            let parts = arg.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, let key = KeyName(rawValue: String(parts[0])) else { return nil }
            let count = parts.count == 2 ? Int(parts[1]) : 1
            guard let count, count >= 1 else { return nil }
            return step(.key(key, count: count))
        case "shortcut":
            return KeyCombo.parse(arg).map { step(.shortcut($0)) }
        case "delay":
            guard let ms = Int(arg), ms >= 0 else { return nil }
            return step(.delay(milliseconds: ms))
        case "openApp":
            return step(.openApp(path: arg))
        case "runShortcut":
            return step(.runShortcut(name: arg))
        default:
            return nil
        }
    }

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) }
    }

    /// `<format>` or `<shift>:<format>`. A first part starting with + or - must be a valid shift,
    /// so a typo like `+1x:` stays literal instead of becoming a strange format.
    private static func dateTime(_ arg: String, _ context: some EvaluationContext) -> String? {
        let parts = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let sign = parts[0].first, sign == "+" || sign == "-" else {
            return format(context.now, arg, date: .short, time: .short, context)
        }
        guard let shifted = shift(context.now, by: parts[0], in: context.timeZone) else { return nil }
        return format(shifted, String(parts[1]), date: .short, time: .short, context)
    }

    /// Applies `^([+-]\d+[yMwdhms])+$` left to right on the Gregorian calendar; nil if it doesn't match.
    private static func shift(_ date: Date, by spec: Substring, in timeZone: TimeZone) -> Date? {
        let units: [Character: Calendar.Component] = [
            "y": .year, "M": .month, "w": .weekOfYear, "d": .day, "h": .hour, "m": .minute, "s": .second,
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var date = date
        var rest = spec
        while let sign = rest.first {
            guard sign == "+" || sign == "-" else { return nil }
            let digits = rest.dropFirst().prefix { ("0"..."9").contains($0) }
            rest = rest.dropFirst(1 + digits.count)
            guard let n = Int(digits), let unit = rest.first.flatMap({ units[$0] }),
                  let next = calendar.date(byAdding: unit, value: sign == "-" ? -n : n, to: date)
            else { return nil }
            rest = rest.dropFirst()
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
