import Foundation

enum LaunchPlan: Equatable, Sendable {
    case typeIntoFrontTerminal(String)
    case appleScript(String)
    case run(executable: String, arguments: [String])
    case openURL(URL)
}

enum LaunchPlanner {
    static let openExecutable = "/usr/bin/open"
    private static let placeholder = "{command}"

    static func plan(_ command: SSHCommand, frontBundleID: String?, settings: TerminalSettings) -> LaunchPlan {
        let line = command.shellLine
        if let frontBundleID, settings.terminalBundleIDs.contains(frontBundleID) { return .typeIntoFrontTerminal(line) }
        switch settings.whenNoTerminal {
        case .custom(let template):
            return .run(executable: "/bin/sh", arguments: ["-c", fill(template, with: line)])
        case .preset(.terminal, _):
            return .appleScript(terminalScript(line))
        case .preset(.iterm2, let newTab):
            return .appleScript(iTermScript(line, newTab: newTab))
        case .preset(.ghostty, _):
            // -e passes what follows as argv with no shell expansion, so the line stays one argument.
            // Not `-e ssh …`: a Ghostty that joins -e's arguments with spaces would lose their quoting.
            return .run(executable: openExecutable, arguments: ["-na", "Ghostty.app", "--args", "-e", "/bin/sh", "-c", line])
        }
    }

    /// A host URLComponents can't represent gives an empty `vnc://`, so it can't change where the URL points.
    static func vncURL(host: String, port: Int, user: String?) -> URL {
        var components = URLComponents()
        components.scheme = "vnc"
        components.user = user?.isEmpty == false ? user : nil
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = port < 0 ? nil : port // URLComponents traps on a negative port
        return components.url ?? URL(string: "vnc://")!
    }

    /// The line as an AppleScript string literal. Replaces scalars, for the reason in `ShellQuote.quote`.
    static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: #"[\\"]"#, with: #"\\$0"#, options: .regularExpression) + "\""
    }

    private static func terminalScript(_ line: String) -> String {
        """
        tell application id "\(TerminalPreset.terminal.bundleID)"
            activate
            do script \(appleScriptString(line))
        end tell
        """
    }

    /// `write text`, not `command`: a session started with `command` closes when ssh exits.
    private static func iTermScript(_ line: String, newTab: Bool) -> String {
        let text = appleScriptString(line)
        return newTab ? """
        tell application id "\(TerminalPreset.iterm2.bundleID)"
            activate
            if (count of windows) is 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window to write text \(text)
        end tell
        """ : """
        tell application id "\(TerminalPreset.iterm2.bundleID)"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow to write text \(text)
        end tell
        """
    }

    /// Puts `line` at each `{command}` as one quoted word. Where the template has a quote open, that
    /// quote closes around the word and reopens, because a plain substitution would unquote the value.
    /// shortcut: reads only `'`, `"` and `\`, so a placeholder inside `"$(…)"` isn't protected; a
    /// template can't be refused here, so if that matters, have Settings reject such templates.
    private static func fill(_ template: String, with line: String) -> String {
        let source = template.contains(placeholder) ? template : template + " " + placeholder
        var rest = Substring(source).unicodeScalars
        var filled = String.UnicodeScalarView()
        var open: Unicode.Scalar?
        while let c = rest.first {
            if rest.starts(with: placeholder.unicodeScalars) {
                let edge = open.map { String($0) } ?? ""
                filled.append(contentsOf: (edge + ShellQuote.quote(line) + edge).unicodeScalars)
                rest = rest.dropFirst(placeholder.unicodeScalars.count)
                continue
            }
            filled.append(c)
            rest = rest.dropFirst()
            switch (open, c) {
            case (nil, "'"), (nil, "\""):
                open = c
            case (nil, "\\"), ("\"", "\\"): // the escaped scalar is copied as text, even a placeholder's `{`
                if let next = rest.popFirst() { filled.append(next) }
            case (let quote?, _) where quote == c:
                open = nil
            default:
                break
            }
        }
        return String(filled)
    }
}
