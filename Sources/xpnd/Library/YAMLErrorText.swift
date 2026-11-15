import Foundation

/// A decoding error as a sentence for the load-error banner and the import message, not Swift's dump of
/// `DecodingError` (`keyNotFound(CodingKeys(stringValue: "text"…`). Yams' own parse errors already name the line.
enum YAMLErrorText {
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return String(describing: error) }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(place(context.codingPath)) has no “\(key.stringValue)”."
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(place(context.codingPath)) isn't the kind of value xpnd expects there."
        case .dataCorrupted(let context):
            if let underlying = context.underlyingError { return String(describing: underlying) }
            return "\(place(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    /// `groups › 1 › snippets › 3`, counting from 1 as a reader of the file does.
    private static func place(_ path: [any CodingKey]) -> String {
        guard !path.isEmpty else { return "The file" }
        return path.map { $0.intValue.map { "item \($0 + 1)" } ?? $0.stringValue }.joined(separator: " › ")
    }
}
