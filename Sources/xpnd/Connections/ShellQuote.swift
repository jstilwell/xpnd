import Foundation

enum ShellQuote {
    private static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-".unicodeScalars)

    /// POSIX single-quote form. Works on scalars, not Characters: `'` plus a combining
    /// mark is one Character, but the shell still sees a quote.
    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#, options: .literal) + "'"
    }

    /// POSIX-like word splitting. Never expands variables, commands, globs or `~`.
    static func split(_ s: String) throws(SSHCommandError) -> [String] {
        var words: [String] = []
        var word: String? // nil between words, so `''` still yields an empty word
        var quote: Unicode.Scalar?
        var scalars = s.unicodeScalars.makeIterator()

        func add(_ scalar: Unicode.Scalar) {
            word = word ?? ""
            word?.unicodeScalars.append(scalar)
        }

        while let c = scalars.next() {
            switch (quote, c) {
            case (nil, " "), (nil, "\t"), (nil, "\n"), (nil, "\r"):
                if let finished = word { words.append(finished) }
                word = nil
            case (nil, "'"), (nil, "\""):
                quote = c
                word = word ?? ""
            case (nil, "\\"):
                guard let next = scalars.next() else { throw .unbalancedQuote }
                add(next)
            case ("\"", "\\"):
                guard let next = scalars.next() else { throw .unbalancedQuote }
                if !["\"", "\\", "$", "`"].contains(next) { add(c) }
                add(next)
            case (let open?, _) where open == c:
                quote = nil
            default:
                add(c)
            }
        }
        if quote != nil { throw .unbalancedQuote }
        if let finished = word { words.append(finished) }
        return words
    }
}
