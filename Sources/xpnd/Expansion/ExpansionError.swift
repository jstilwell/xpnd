enum ExpansionError: Error, Equatable, Sendable {
    case missingCombo(String)
    case comboCycle(String)
    case comboTooDeep
    case scriptNotFound(path: String)
    case scriptNotExecutable(path: String)
    case scriptFailed(path: String, status: Int32)
    case scriptTimedOut(path: String)
    case scriptOutputTooLarge(path: String)
    case inputCancelled
    case appNotFound(path: String)
    case unknownShortcut(String)
    case shortcutsUnavailable
    case shortcutFailed(name: String, status: Int32)
    case shortcutTimedOut(String)
    case targetAppChanged
    case expansionTurnedOff
    case busy

    var message: String {
        switch self {
        case .missingCombo(let k): "No snippet has the keyword “\(k)”."
        case .comboCycle(let k): "The snippet “\(k)” includes itself, so it can't expand."
        case .comboTooDeep: "Snippets include each other too deeply to expand (over 16 levels or 10,000 pieces)."
        case .scriptNotFound(let path): "No script was found at “\(path)”."
        case .scriptNotExecutable(let path): "The script “\(path)” isn't executable. Run chmod +x on it."
        case .scriptFailed(let path, let status): "The script “\(path)” failed with exit status \(status)."
        case .scriptTimedOut(let path): "The script “\(path)” took too long and was stopped."
        case .scriptOutputTooLarge(let path): "The script “\(path)” printed more than 8 MB and was stopped."
        case .inputCancelled: "The input form was cancelled."
        case .appNotFound(let path): "No app was found at “\(path)”."
        case .unknownShortcut(let name): "No shortcut is named “\(name)”."
        case .shortcutsUnavailable: "Couldn't read your list of Shortcuts."
        case .shortcutFailed(let name, let status): "The shortcut “\(name)” failed with exit status \(status)."
        case .shortcutTimedOut(let name): "The shortcut “\(name)” took too long and was stopped."
        case .targetAppChanged: "Expansion cancelled: the app you typed in is no longer in front."
        case .expansionTurnedOff: "Expansion cancelled: expansion was turned off."
        case .busy: "Another action is still running."
        }
    }
}
