import Foundation

/// One `#{…}` in the editor: where it is, and why it won't expand (nil when it will).
struct TemplateMark: Equatable {
    let range: NSRange
    let problem: String?
}

/// The editor's checks. They read variables through `Variable.parse`, as `Evaluator` does, so the two can't disagree.
enum TemplateCheck {
    /// `keyword`: the snippet being edited, which can't include itself.
    static func marks(in text: String, keyword: String, library: SnippetLibrary) -> [TemplateMark] {
        Template.parseWithRanges(text).compactMap { token, range in
            guard case let .variable(name, argument, _) = token else { return nil }
            switch Variable.parse(name: name, argument: argument) {
            case .failure(let problem):
                return TemplateMark(range: range, problem: problem.message)
            case .success(.snippet(let k, _)) where k == keyword:
                return TemplateMark(range: range, problem: "This snippet can't include itself.")
            case .success(.snippet(let k, _)) where library.snippet(keyword: k) == nil:
                return TemplateMark(range: range, problem: "No snippet has the keyword “\(k)”.")
            case .success:
                return TemplateMark(range: range, problem: nil)
            }
        }
    }
}
