import Foundation

enum TemplateToken: Equatable, Sendable {
    case text(String)
    /// `raw` is the exact source text, including `#{`, `}` and any backslashes.
    case variable(name: String, argument: String?, raw: String)
}

enum Template {
    /// Splits snippet text into literal text and `#{name:argument}` variables.
    /// Anything that starts with `#{` but isn't a well-formed variable stays text.
    static func parse(_ text: String) -> [TemplateToken] { parseWithRanges(text).map(\.token) }

    /// `parse`, with where each token sits in UTF-16 units, as `NSTextView` counts.
    static func parseWithRanges(_ text: String) -> [(token: TemplateToken, range: NSRange)] {
        let chars = Array(text)
        var tokens: [(token: TemplateToken, range: NSRange)] = []
        var pending = ""
        var offset = 0 // UTF-16 offset of chars[i]
        var pendingStart = 0
        var i = 0
        func flush() {
            guard !pending.isEmpty else { return }
            tokens.append((.text(pending), NSRange(location: pendingStart, length: offset - pendingStart)))
            pending = ""
        }
        while i < chars.count {
            if let (token, end) = variable(in: chars, at: i) {
                flush()
                let length = chars[i..<end].reduce(0) { $0 + $1.utf16.count }
                tokens.append((token, NSRange(location: offset, length: length)))
                offset += length
                i = end
            } else {
                if pending.isEmpty { pendingStart = offset }
                pending.append(chars[i])
                offset += chars[i].utf16.count
                i += 1
            }
        }
        flush()
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
