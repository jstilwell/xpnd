enum ExpansionError: Error, Equatable, Sendable {
    case missingCombo(String)
    case scriptNotFound(path: String)
    case scriptFailed(path: String, status: Int32)
    case scriptTimedOut(path: String)
    case inputCancelled
    case appNotFound(path: String)
    case unknownShortcut(String)
    case shortcutFailed(name: String, status: Int32)
    case shortcutTimedOut(String)

    var message: String {
        switch self {
        case .missingCombo(let k): "No snippet has the keyword “\(k)”."
        case .scriptNotFound(let path): "No script was found at “\(path)”."
        case .scriptFailed(let path, let status): "The script “\(path)” failed with exit status \(status)."
        case .scriptTimedOut(let path): "The script “\(path)” took too long and was stopped."
        case .inputCancelled: "The input form was cancelled."
        case .appNotFound(let path): "No app was found at “\(path)”."
        case .unknownShortcut(let name): "No shortcut is named “\(name)”."
        case .shortcutFailed(let name, let status): "The shortcut “\(name)” failed with exit status \(status)."
        case .shortcutTimedOut(let name): "The shortcut “\(name)” took too long and was stopped."
        }
    }
}
