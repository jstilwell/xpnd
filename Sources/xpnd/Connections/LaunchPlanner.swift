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

    static func plan(_ command: SSHCommand, frontBundleID: String?, settings: TerminalSettings) throws(LaunchError) -> LaunchPlan {
        let line = command.shellLine
        if let frontBundleID, settings.terminalBundleIDs.contains(frontBundleID) { return .typeIntoFrontTerminal(line) }
        switch settings.whenNoTerminal {
        case .custom(let template):
            if let problem = templateProblem(template) { throw .badTemplate(problem) }
            let script = completed(template).replacingOccurrences(of: placeholder, with: ShellQuote.quote(line), options: .literal)
            return .run(executable: "/bin/sh", arguments: ["-c", script])
        case .preset(.terminal, _):
            return .appleScript(terminalScript(line))
        case .preset(.iterm2, let newTab):
            return .appleScript(iTermScript(line, newTab: newTab))
        case .preset(.ghostty, _):
            // The one /bin/sh -c besides templates: the line stays one argv entry, where `-e ssh …` loses its quoting on a Ghostty that joins -e's arguments.
            return .run(executable: openExecutable, arguments: ["-na", "Ghostty.app", "--args", "-e", "/bin/sh", "-c", line])
        }
    }

    /// Refuses what can't be a real address, so a bad host fails here rather than opening nothing.
    static func vncURL(host: String, port: Int, user: String?) throws(LaunchError) -> URL {
        let invalid = LaunchError.failed("That VNC host isn't valid.")
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        let isIPv6 = !bare.utf8.contains(0) && inet_pton(AF_INET6, bare, &address) == 1
        guard !host.isEmpty, (1...65535).contains(port), isIPv6 || bare == host else { throw invalid }
        var components = URLComponents()
        components.scheme = "vnc"
        components.user = user?.isEmpty == false ? user : nil
        components.host = isIPv6 ? "[\(bare)]" : host
        components.port = port
        guard let url = components.url else { throw invalid }
        return url
    }

    /// Why a template can't be run, or nil. Plain substitution is only safe where `{command}` is
    /// outside every quote: inside one, the word's own quotes flip the template's and unquote the value.
    /// Scalars, not Characters, for the reason in `ShellQuote.quote`.
    static func templateProblem(_ template: String) -> String? {
        func has(_ text: String) -> Bool { template.range(of: text, options: .literal) != nil }
        if ["`", "$(", "$'", "<<"].contains(where: has) {
            return "Custom commands can't use backticks, $(…), $'…' or <<, because {command} can't stay quoted there."
        }
        // `${command}` would become `$'…'`, where backslashes are live.
        if has("\\" + placeholder) || has("$" + placeholder) { return "{command} can't come right after a backslash or $." }
        var rest = Substring(completed(template)).unicodeScalars
        var open: Unicode.Scalar?
        while let c = rest.popFirst() {
            switch (open, c) {
            case (nil, "'"), (nil, "\""):
                open = c
            case (nil, "\\"), ("\"", "\\"):
                _ = rest.popFirst()
            case (let quote?, _) where quote == c:
                open = nil
            default:
                break
            }
            if open != nil, rest.starts(with: placeholder.unicodeScalars) { return "Leave {command} outside quotes: xpnd quotes it for you." }
        }
        return nil
    }

    /// The template as it will run: one without `{command}` gets it appended.
    private static func completed(_ template: String) -> String {
        template.range(of: placeholder, options: .literal) == nil ? template + " " + placeholder : template
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
}
