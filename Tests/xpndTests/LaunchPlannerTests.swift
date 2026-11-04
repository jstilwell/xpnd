import Foundation
import Testing
@testable import xpnd

private let line = SSHCommand(arguments: ["ssh", "-p", "2222", "me@host"])
/// Needs AppleScript's escapes: `ssh 'a"b'\\'c'`.
private let quoted = SSHCommand(arguments: ["ssh", #"a"b\c"#])

private func settings(_ action: NoTerminalAction) -> TerminalSettings {
    TerminalSettings(terminalBundleIDs: TerminalSettings.standard.terminalBundleIDs, whenNoTerminal: action)
}

private func plan(_ command: SSHCommand, _ action: NoTerminalAction) throws(LaunchError) -> LaunchPlan {
    try LaunchPlanner.plan(command, frontBundleID: "com.apple.Safari", settings: settings(action))
}

/// What a shell really receives. Harmless on purpose: a quoting bug here prints, or fails the test.
private func stdout(of plan: LaunchPlan) async throws -> String {
    guard case .run(let executable, let arguments) = plan else {
        Issue.record("expected .run, got \(plan)")
        return ""
    }
    return try await ProcessRunner.run(URL(fileURLWithPath: executable), arguments: arguments, timeoutMs: 5000).stdout
}

private let hostileHosts = [
    "a;echo pwned", "$(echo pwned)", "`echo pwned`", "$HOME", "a b", "it's", "'", "''", "\"", "\\", "\\'", "'\"",
    "'\u{301};echo pwned;'", "a&echo pwned", "a|echo pwned", "{command}", "'{command}'",
]

@Suite struct LaunchPlannerTests {
    @Test func terminalInFrontTypes() throws {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"] {
            #expect(try LaunchPlanner.plan(line, frontBundleID: id, settings: .standard) == .typeIntoFrontTerminal(line.shellLine))
        }
        let edited = TerminalSettings(terminalBundleIDs: ["com.example.term"], whenNoTerminal: .custom(template: "x"))
        #expect(try LaunchPlanner.plan(line, frontBundleID: "com.example.term", settings: edited) == .typeIntoFrontTerminal(line.shellLine))
    }

    @Test func noTerminalInFrontOpensOne() throws {
        for front in ["com.apple.Safari", nil] {
            guard case .appleScript = try LaunchPlanner.plan(line, frontBundleID: front, settings: .standard) else {
                Issue.record("a terminal was assumed for \(front ?? "nil")")
                continue
            }
        }
    }

    @Test func presetTerminalScript() throws {
        #expect(try plan(quoted, .preset(.terminal, newTab: false)) == .appleScript(#"""
        tell application id "com.apple.Terminal"
            activate
            do script "ssh 'a\"b'\\\\'c'"
        end tell
        """#))
    }

    @Test func presetITermScript() throws {
        #expect(try plan(quoted, .preset(.iterm2, newTab: false)) == .appleScript(#"""
        tell application id "com.googlecode.iterm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow to write text "ssh 'a\"b'\\\\'c'"
        end tell
        """#))
    }

    @Test func presetITermTab() throws {
        #expect(try plan(quoted, .preset(.iterm2, newTab: true)) == .appleScript(#"""
        tell application id "com.googlecode.iterm2"
            activate
            if (count of windows) is 0 then
                create window with default profile
            else
                tell current window to create tab with default profile
            end if
            tell current session of current window to write text "ssh 'a\"b'\\\\'c'"
        end tell
        """#))
    }

    @Test func presetGhostty() throws {
        #expect(try plan(quoted, .preset(.ghostty, newTab: false)) == .run(
            executable: "/usr/bin/open",
            arguments: ["-na", "Ghostty.app", "--args", "-e", "/bin/sh", "-c", quoted.shellLine]))
    }

    @Test func newTabFallsBackToNewWindow() throws {
        #expect(TerminalPreset.allCases.filter(\.supportsTabs) == [.iterm2])
        for preset in TerminalPreset.allCases where !preset.supportsTabs {
            #expect(try plan(line, .preset(preset, newTab: true)) == (try plan(line, .preset(preset, newTab: false))))
        }
    }

    @Test func appleScriptEscapes() {
        #expect(LaunchPlanner.appleScriptString(#"""#) == #""\"""#)
        #expect(LaunchPlanner.appleScriptString(#"\"#) == #""\\""#)
        #expect(LaunchPlanner.appleScriptString(#"\""#) == #""\\\"""#)
        #expect(LaunchPlanner.appleScriptString("$(id)") == #""$(id)""#)
        #expect(LaunchPlanner.appleScriptString("it's") == #""it's""#)
    }

    @Test func longLinesStayWhole() throws {
        let long = SSHCommand(arguments: ["ssh", String(repeating: "a", count: 12_000)])
        for action in [NoTerminalAction.preset(.terminal, newTab: false), .preset(.iterm2, newTab: false)] {
            guard case .appleScript(let script) = try plan(long, action) else {
                Issue.record("expected .appleScript")
                continue
            }
            #expect(script.contains(long.shellLine))
        }
        #expect(try plan(long, .custom(template: "t {command}")) == .run(
            executable: "/bin/sh", arguments: ["-c", "t " + ShellQuote.quote(long.shellLine)]))
    }

    @Test func templateQuotesCommand() throws {
        #expect(try plan(line, .custom(template: "tmux new-window {command}")) == .run(
            executable: "/bin/sh", arguments: ["-c", "tmux new-window 'ssh -p 2222 me@host'"]))
        #expect(try plan(line, .custom(template: "t {command} {command}")) == .run(
            executable: "/bin/sh", arguments: ["-c", "t 'ssh -p 2222 me@host' 'ssh -p 2222 me@host'"]))
        #expect(try plan(line, .custom(template: "t x{command}{command}y")) == .run(
            executable: "/bin/sh", arguments: ["-c", "t x'ssh -p 2222 me@host''ssh -p 2222 me@host'y"]))
    }

    @Test func hostileHostsSurviveTheShell() async throws {
        for host in hostileHosts {
            let hostile = SSHCommand(arguments: ["ssh", host])
            let shellLine = hostile.shellLine
            let templates = [
                ("printf %s {command}", shellLine), ("printf %s", shellLine),
                ("printf %s {command} {command}", shellLine + shellLine),
                ("printf %s x{command}y", "x\(shellLine)y"), ("printf %s {command}{command}", shellLine + shellLine),
                (#"printf %s \'{command}"#, "'" + shellLine), (#"printf %s "it's"{command}"#, "it's" + shellLine),
            ]
            for (template, printed) in templates {
                #expect(try await stdout(of: plan(hostile, .custom(template: template))) == printed, "\(template) with \(host)")
            }
        }
    }

    @Test(arguments: [
        "t '{command}'", #"t "{command}""#, #"t \{command}"#, #"t \\{command}"#, "t ${command}", #"t "$(echo {command})""#,
        "t $(echo {command})", "t `echo {command}`", "cat <<EOF", "t <<<{command}", "t $'{command}'", #"sh -c "sh -c '{command}'""#,
        "it's {command}", #"t " {command}"#, "t '", #"t ""#, #"t "it's {command}""#, "t '\u{301} {command}", "`\u{301} {command}",
        #"printf %s "${X:-"{command}"}""#, #"sh -c "${WRAP:-"{command}"}""#, #""${X#"{command}}{command}x'"#, "t ${HOME} {command}",
        "printf %s $[{command}]", "printf %s $[ {command} ]", #"printf %s $'\'' "' {command}""#,
    ])
    func unsafeTemplatesAreRefused(template: String) throws {
        let reason = try #require(LaunchPlanner.templateProblem(template))
        #expect(throws: LaunchError.badTemplate(reason)) { try plan(line, .custom(template: template)) }
    }

    @Test(arguments: [
        "t {command}", "t {command} {command}", "t x{command}y", "t", "", "t 'a b' {command}", #"t "it's" {command}"#,
        #"t \' {command}"#, #"t "\"" {command}"#, "t $HOME {command}", "t {command} 'a'x",
    ])
    func safeTemplatesAreAccepted(template: String) {
        #expect(LaunchPlanner.templateProblem(template) == nil)
    }

    @Test func templateWithoutPlaceholder() throws {
        #expect(try plan(line, .custom(template: "my-launcher --run")) == .run(
            executable: "/bin/sh", arguments: ["-c", "my-launcher --run 'ssh -p 2222 me@host'"]))
    }

    @Test func launchEnvironmentFindsHomebrew() {
        let homebrew = "/opt/homebrew/bin:/usr/local/bin:"
        #expect(LiveLaunchExecutor.launchEnvironment(["PATH": "/usr/bin:/bin", "HOME": "/h"]) == ["PATH": homebrew + "/usr/bin:/bin", "HOME": "/h"])
        for inherited: [String: String] in [[:], ["PATH": ""]] {
            #expect(LiveLaunchExecutor.launchEnvironment(inherited) == ["PATH": homebrew + "/usr/bin:/bin:/usr/sbin:/sbin"])
        }
    }

    @Test func vncURLEncodesUser() throws {
        #expect(try LaunchPlanner.vncURL(host: "mac.example.com", port: 5900, user: "a b@c:d/e").absoluteString
            == "vnc://a%20b%40c%3Ad%2Fe@mac.example.com:5900")
        #expect(try LaunchPlanner.vncURL(host: "mac.example.com", port: 5901, user: nil).absoluteString == "vnc://mac.example.com:5901")
        #expect(try LaunchPlanner.vncURL(host: "mac.example.com", port: 5900, user: "").absoluteString == "vnc://mac.example.com:5900")
    }

    @Test func vncURLBracketsIPv6() throws {
        #expect(try LaunchPlanner.vncURL(host: "::1", port: 5900, user: nil).absoluteString == "vnc://[::1]:5900")
        #expect(try LaunchPlanner.vncURL(host: "[::1]", port: 5900, user: nil).absoluteString == "vnc://[::1]:5900")
    }

    @Test(arguments: [
        "", "host.local:5901", "evil.com/x?y#z", "a@b.com", "a b", "a:b/c", ":::::", "[:::::]", "[host]", "[", "::1\0x", "h\0x",
    ])
    func vncURLRefusesBadHosts(host: String) {
        #expect(throws: LaunchError.failed("That VNC host isn't valid.")) { try LaunchPlanner.vncURL(host: host, port: 5900, user: "me") }
    }

    @Test func vncURLKeepsZoneID() throws {
        #expect(try LaunchPlanner.vncURL(host: "fe80::1%en0", port: 5900, user: nil).absoluteString == "vnc://[fe80::1%25en0]:5900")
    }

    @Test(arguments: [-1, 0, 65536])
    func vncURLRefusesBadPorts(port: Int) {
        #expect(throws: LaunchError.failed("That VNC host isn't valid.")) { try LaunchPlanner.vncURL(host: "h", port: port, user: nil) }
    }

    @Test func vncURLAcceptsPortLimits() throws {
        #expect(try LaunchPlanner.vncURL(host: "h", port: 1, user: nil).absoluteString == "vnc://h:1")
        #expect(try LaunchPlanner.vncURL(host: "h", port: 65535, user: nil).absoluteString == "vnc://h:65535")
    }

    @MainActor @Test func settingsRoundTrip() throws {
        let suite = "LaunchPlannerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let edited = TerminalSettings(terminalBundleIDs: ["com.example.term"], whenNoTerminal: .custom(template: "t {command}"))

        #expect(AppSettings(defaults: defaults).terminal == .standard)
        AppSettings(defaults: defaults).terminal = edited
        #expect(AppSettings(defaults: defaults).terminal == edited)
        AppSettings(defaults: defaults).terminal.whenNoTerminal = .preset(.iterm2, newTab: true)
        #expect(AppSettings(defaults: defaults).terminal.whenNoTerminal == .preset(.iterm2, newTab: true))
    }

    @Test func standardSettings() {
        #expect(TerminalSettings.standard.terminalBundleIDs
            == ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"])
        #expect(TerminalSettings.standard.whenNoTerminal == .preset(.terminal, newTab: false))
    }

    /// The missing-app lines are what osascript and open really print. The denied lines were not captured: no prompt was triggered.
    @Test func failuresMapToErrors() {
        #expect(LiveLaunchExecutor.appleScriptError(
            #"5:43: syntax error: Can’t get application id "com.googlecode.iterm2". (-1728)"#) == .appMissing("iTerm2"))
        #expect(LiveLaunchExecutor.appleScriptError("0:60: execution error: Not authorized to send Apple events to Terminal. (-1743)")
            == .appleScriptDenied)
        #expect(LiveLaunchExecutor.appleScriptError("execution error: Terminal is not allowed to do that.") == .appleScriptDenied)
        let other = LiveLaunchExecutor.appleScriptError(#"0:9: execution error: Can’t get window 1 "ssh secret". (-1728)"#)
        #expect(other == .appleScriptFailed("The terminal couldn't run the command."))
        #expect(LiveLaunchExecutor.openError("Unable to find application named 'Ghostty.app'") == .appMissing("Ghostty"))
        #expect(LiveLaunchExecutor.openError("LSOpenURLsWithRole() failed") == .failed("Ghostty couldn't be opened."))
    }

    @Test func errorsHaveMessages() {
        #expect(LaunchError.appMissing("iTerm2").message == "iTerm2 isn't installed.")
        #expect(LaunchError.failed("Nope.").message == "Nope.")
        #expect(LaunchError.badTemplate("Nope.").message == "Nope.")
        #expect(LaunchError.appleScriptFailed("Nope.").message == "Nope.")
        #expect(LaunchError.appleScriptDenied.message.contains("Automation"))
    }
}
