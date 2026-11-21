import Foundation

/// Why a `#{…}` won't expand, in words for the editor's tooltip.
struct VariableProblem: Error, Equatable, Sendable {
    let message: String
}

/// One `#{name:argument}`, read once. The evaluator, the editor's checks, the preview and the variable forms all use
/// this, so they can't disagree about what a variable means.
enum Variable: Equatable, Sendable {
    enum Transform: String, CaseIterable, Sendable { case trim, upper, lower }
    enum Case: Sendable { case plain, upper, lower }

    case clipboard(Transform?)
    case selection(Transform?)
    case date(shift: String?)
    case time(shift: String?)
    /// An empty format means the short date and time styles.
    case dateTime(shift: String?, format: String)
    case snippet(keyword: String, Case)
    case cursor
    case input(label: String, default: String)
    case choice(label: String, options: [String])
    case longInput(label: String)
    case envVar(String)
    case script(path: String, timeoutMs: Int?)
    case key(KeyName, count: Int)
    case shortcut(String)
    case delay(Int)
    case openApp(String)
    case runShortcut(String)
    case uuid
    case fullName

    static let defaultScriptTimeoutMs = 10_000

    static func parse(name: String, argument: String?) -> Result<Variable, VariableProblem> {
        func fail(_ message: String) -> Result<Variable, VariableProblem> { .failure(VariableProblem(message: message)) }
        let known = ["clipboard", "selection", "date", "time", "dateTime", "combo", "upper", "lower", "cursor", "input",
                     "choice", "longInput", "envVar", "shell", "key", "shortcut", "delay", "openApp", "runShortcut", "uuid",
                     "fullName"]
        guard known.contains(name) else { return fail("xpnd has no variable “#{\(name)}”.") }

        guard let arg = argument else {
            switch name {
            case "clipboard": return .success(.clipboard(nil))
            case "selection": return .success(.selection(nil))
            case "date": return .success(.date(shift: nil))
            case "time": return .success(.time(shift: nil))
            case "dateTime": return .success(.dateTime(shift: nil, format: ""))
            case "cursor": return .success(.cursor)
            case "uuid": return .success(.uuid)
            case "fullName": return .success(.fullName)
            default: return fail(needs(name))
            }
        }
        guard !arg.isEmpty else { return fail(needs(name)) }
        switch name {
        case "cursor", "uuid", "fullName":
            return fail("#{\(name)} takes nothing after a colon.")
        case "clipboard", "selection":
            guard let t = Transform(rawValue: arg) else { return fail("“\(arg)” isn't trim, upper or lower.") }
            return .success(name == "clipboard" ? .clipboard(t) : .selection(t))
        case "date", "time":
            guard isShift(arg) else { return fail(notShift(arg)) }
            return .success(name == "date" ? .date(shift: arg) : .time(shift: arg))
        case "dateTime":
            // A first part starting with + or - must be a valid shift, so a typo like `+1x:` doesn't become a strange format.
            let parts = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let sign = parts[0].first, sign == "+" || sign == "-" else {
                return .success(.dateTime(shift: nil, format: arg))
            }
            guard isShift(String(parts[0])) else { return fail(notShift(String(parts[0]))) }
            return .success(.dateTime(shift: String(parts[0]), format: String(parts[1])))
        case "combo": return .success(.snippet(keyword: arg, .plain))
        case "upper": return .success(.snippet(keyword: arg, .upper))
        case "lower": return .success(.snippet(keyword: arg, .lower))
        case "input":
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard !parts[0].isEmpty else { return fail(needs(name)) }
            return .success(.input(label: String(parts[0]), default: parts.count == 2 ? String(parts[1]) : ""))
        case "choice":
            let parts = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                return fail("Choice needs a label and options, like #{choice:Size:S|M|L}.")
            }
            let options = parts[1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard !options.contains(where: \.isEmpty) else { return fail("A choice option is empty.") }
            return .success(.choice(label: String(parts[0]), options: options))
        case "longInput": return .success(.longInput(label: arg))
        case "envVar": return .success(.envVar(arg))
        case "shell":
            if let colon = arg.lastIndex(of: ":"), case let digits = arg[arg.index(after: colon)...], isDigits(digits) {
                guard let t = Int(digits) else { return fail("“\(digits)” is too long a timeout.") }
                let path = String(arg[..<colon])
                guard !path.isEmpty else { return fail(needs(name)) }
                return .success(.script(path: path, timeoutMs: t))
            }
            return .success(.script(path: arg, timeoutMs: nil))
        case "key":
            let parts = arg.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2, let key = KeyName(rawValue: String(parts[0])) else {
                return fail("“\(parts[0])” isn't a key name.")
            }
            guard parts.count == 2 else { return .success(.key(key, count: 1)) }
            guard let count = Int(parts[1]), count >= 1 else { return fail("“\(parts[1])” isn't a count of 1 or more.") }
            return .success(.key(key, count: count))
        case "shortcut":
            guard KeyCombo.parse(arg) != nil else {
                return fail("“\(arg)” isn't a shortcut, like Cmd+Shift+J (Cmd, Option, Control, Shift, then a key).")
            }
            return .success(.shortcut(arg))
        case "delay":
            guard let ms = Int(arg), ms >= 0 else { return fail("“\(arg)” isn't a number of milliseconds.") }
            return .success(.delay(ms))
        case "openApp": return .success(.openApp(arg))
        default: return .success(.runShortcut(arg)) // "runShortcut", the last known name
        }
    }

    /// The source text, with `\` and `}` escaped in the argument.
    var template: String {
        func t(_ name: String, _ argument: String? = nil) -> String {
            guard let argument else { return "#{\(name)}" }
            let escaped = argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "}", with: "\\}")
            return "#{\(name):\(escaped)}"
        }
        switch self {
        case .clipboard(let x): return t("clipboard", x?.rawValue)
        case .selection(let x): return t("selection", x?.rawValue)
        case .date(let shift): return t("date", shift)
        case .time(let shift): return t("time", shift)
        case let .dateTime(shift, format):
            if let shift { return t("dateTime", "\(shift):\(format)") }
            return t("dateTime", format.isEmpty ? nil : format)
        case let .snippet(keyword, c):
            return t(c == .plain ? "combo" : c == .upper ? "upper" : "lower", keyword)
        case .cursor: return t("cursor")
        case let .input(label, def): return t("input", def.isEmpty ? label : "\(label)=\(def)")
        case let .choice(label, options): return t("choice", "\(label):\(options.joined(separator: "|"))")
        case .longInput(let label): return t("longInput", label)
        case .envVar(let name): return t("envVar", name)
        case let .script(path, timeout):
            // A path that ends in `:digits` would read back as a timeout, so then the timeout is written out.
            let endsInTimeout = path.lastIndex(of: ":").map { Self.isDigits(path[path.index(after: $0)...]) } ?? false
            let ms = timeout ?? (endsInTimeout ? Self.defaultScriptTimeoutMs : nil)
            return t("shell", ms.map { "\(path):\($0)" } ?? path)
        case let .key(key, count): return t("key", count == 1 ? key.rawValue : "\(key.rawValue):\(count)")
        case .shortcut(let s): return t("shortcut", s)
        case .delay(let ms): return t("delay", String(ms))
        case .openApp(let path): return t("openApp", path)
        case .runShortcut(let name): return t("runShortcut", name)
        case .uuid: return t("uuid")
        case .fullName: return t("fullName")
        }
    }

    private static func needs(_ name: String) -> String {
        switch name {
        case "input", "choice", "longInput": "\(name == "input" ? "Input" : name == "choice" ? "Choice" : "Long input") needs a label."
        case "combo", "upper", "lower": "#{\(name)} needs a snippet keyword."
        case "envVar": "#{envVar} needs a variable name."
        case "shell", "openApp": "#{\(name)} needs a path."
        case "key": "#{key} needs a key name, like tab."
        case "shortcut": "#{shortcut} needs a shortcut, like Cmd+Shift+J."
        case "delay": "#{delay} needs a number of milliseconds."
        case "runShortcut": "#{runShortcut} needs a Shortcut's name."
        default: "#{\(name)} needs something after the colon."
        }
    }

    private static func notShift(_ s: String) -> String { "“\(s)” isn't a date shift, like +1d or -2h." }

    private static func isDigits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) } }

    /// `^([+-]\d+[yMwdhms])+$`, with each count small enough for an `Int`.
    static func isShift(_ spec: String) -> Bool { shiftSteps(spec) != nil }

    /// The steps of a shift spec, left to right; nil if it doesn't match.
    static func shiftSteps(_ spec: String) -> [(Calendar.Component, Int)]? {
        let units: [Character: Calendar.Component] = [
            "y": .year, "M": .month, "w": .weekOfYear, "d": .day, "h": .hour, "m": .minute, "s": .second,
        ]
        var steps: [(Calendar.Component, Int)] = []
        var rest = Substring(spec)
        while let sign = rest.first {
            guard sign == "+" || sign == "-" else { return nil }
            let digits = rest.dropFirst().prefix { ("0"..."9").contains($0) }
            rest = rest.dropFirst(1 + digits.count)
            guard let n = Int(digits), let unit = rest.first.flatMap({ units[$0] }) else { return nil }
            rest = rest.dropFirst()
            steps.append((unit, sign == "-" ? -n : n))
        }
        return steps.isEmpty ? nil : steps
    }
}
