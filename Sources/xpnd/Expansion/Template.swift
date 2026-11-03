enum TemplateToken: Equatable, Sendable {
    case text(String)
    /// `raw` is the exact source text, including `#{`, `}` and any backslashes.
    case variable(name: String, argument: String?, raw: String)
}

enum Template {
    /// Splits snippet text into literal text and `#{name:argument}` variables.
    /// Anything that starts with `#{` but isn't a well-formed variable stays text.
    static func parse(_ text: String) -> [TemplateToken] {
        let chars = Array(text)
        var tokens: [TemplateToken] = []
        var pending = ""
        var i = 0
        while i < chars.count {
            if let (token, end) = variable(in: chars, at: i) {
                if !pending.isEmpty { tokens.append(.text(pending)); pending = "" }
                tokens.append(token)
                i = end
            } else {
                pending.append(chars[i])
                i += 1
            }
        }
        if !pending.isEmpty { tokens.append(.text(pending)) }
        return tokens
    }

    private static func variable(in chars: [Character], at start: Int) -> (TemplateToken, Int)? {
        guard chars[start] == "#", start + 1 < chars.count, chars[start + 1] == "{" else { return nil }
        var i = start + 2
        let nameStart = i
        while i < chars.count, let a = chars[i].asciiValue, (a | 0x20) >= 0x61, (a | 0x20) <= 0x7A { i += 1 }
        guard i > nameStart, i < chars.count else { return nil }
        let name = String(chars[nameStart..<i])
        var argument: String?
        if chars[i] == ":" {
            i += 1
            var arg = ""
            while i < chars.count, chars[i] != "}" {
                if chars[i] == "\\", i + 1 < chars.count, chars[i + 1] == "}" || chars[i + 1] == "\\" {
                    i += 1
                }
                arg.append(chars[i])
                i += 1
            }
            argument = arg
        }
        guard i < chars.count, chars[i] == "}" else { return nil }
        return (.variable(name: name, argument: argument, raw: String(chars[start...i])), i + 1)
    }
}
