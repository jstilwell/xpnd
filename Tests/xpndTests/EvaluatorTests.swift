import Carbon.HIToolbox
import Foundation
import Testing
@testable import xpnd

// Each test builds its own context and evaluates sequentially, so the unlocked state is safe.
private final class FakeContext: EvaluationContext, @unchecked Sendable {
    let now = ISO8601DateFormatter().date(from: "2026-11-03T14:05:09Z")!
    let locale = Locale(identifier: "en_US_POSIX")
    let timeZone = TimeZone(identifier: "UTC")!
    var clipboard: String?
    var env: [String: String] = [:]
    var snippets: [Snippet] = []
    var scriptResult: Result<String, ExpansionError> = .success("")
    var answers: [String: String]? = [:]
    var scriptCalls: [String] = []
    var askedLabels: [[String]] = []

    func clipboardText() async -> String? { clipboard }
    func environment(_ name: String) -> String? { env[name] }
    func snippet(keyword: String) -> Snippet? { snippets.first { $0.keyword == keyword } }

    func runScript(path: String, timeoutMs: Int) async throws(ExpansionError) -> String {
        scriptCalls.append("\(path) \(timeoutMs)")
        return try scriptResult.get()
    }

    func askInputs(_ labels: [String]) async -> [String: String]? {
        askedLabels.append(labels)
        return answers
    }
}

private func snip(_ keyword: String, _ text: String) -> Snippet {
    Snippet(name: keyword, keyword: keyword, text: text)
}

private func run(_ text: String, _ ctx: FakeContext = FakeContext()) async throws(ExpansionError) -> [PlayStep] {
    try await Evaluator.evaluate(snip(";t", text), context: ctx)
}

struct EvaluatorTests {
    @Test func plainTextIsOnePaste() async throws {
        #expect(try await run("hi") == [.paste("hi")])
    }

    @Test func clipboardInsertedOrEmpty() async throws {
        let ctx = FakeContext()
        ctx.clipboard = "x"
        #expect(try await run("[#{clipboard}]", ctx) == [.paste("[x]")])
        #expect(try await run("[#{clipboard}]") == [.paste("[]")])
    }

    @Test func customDateFormats() async throws {
        #expect(try await run("#{dateTime:yyyy-MM-dd}") == [.paste("2026-11-03")])
        #expect(try await run("#{dateTime:HH:mm}") == [.paste("14:05")])
    }

    @Test func dateShift() async throws {
        #expect(try await run("#{dateTime:+1d-2h:yyyy-MM-dd HH}") == [.paste("2026-11-04 12")])
        #expect(try await run("#{dateTime:+1w:yyyy-MM-dd}") == [.paste("2026-11-10")])
    }

    @Test func shiftWithEmptyFormatUsesShortStyles() async throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")!
        f.dateStyle = .short
        f.timeStyle = .short
        let expected = f.string(from: ISO8601DateFormatter().date(from: "2026-12-03T14:05:09Z")!)
        #expect(try await run("#{dateTime:+1M:}") == [.paste(expected)])
    }

    @Test func comboNestsAndCases() async throws {
        let ctx = FakeContext()
        ctx.snippets = [snip(";n", "Bob")]
        #expect(try await run("#{combo:;n} #{upper:;n} #{lower:;n}", ctx) == [.paste("Bob BOB bob")])
    }

    @Test func missingComboThrows() async {
        await #expect(throws: ExpansionError.missingCombo(";zz")) { try await run("a#{combo:;zz}") }
        await #expect(throws: ExpansionError.missingCombo(";zz")) { try await run("#{upper:;zz}") }
    }

    @Test func comboCycleLeftLiteral() async throws {
        let ctx = FakeContext()
        let a = snip("a", "x#{combo:b}")
        ctx.snippets = [a, snip("b", "y#{combo:a}")]
        #expect(try await Evaluator.evaluate(a, context: ctx) == [.paste("xy#{combo:a}")])
    }

    @Test func inputsAskedOnceInOrder() async throws {
        let ctx = FakeContext()
        ctx.snippets = [snip(";team", "T=#{input:Team}")]
        ctx.answers = ["Name": "Ann", "Ticket #": "42", "Team": "Ops"]
        let steps = try await run("#{input:Name} #{input:Ticket #} #{input:Name} #{lower:;team}", ctx)
        #expect(ctx.askedLabels == [["Name", "Ticket #", "Team"]])
        #expect(steps == [.paste("Ann 42 Ann t=ops")])
    }

    @Test func noInputsAsksNothing() async throws {
        let ctx = FakeContext()
        _ = try await run("hi", ctx)
        #expect(ctx.askedLabels.isEmpty)
    }

    @Test func cancelledInputThrows() async {
        let ctx = FakeContext()
        ctx.answers = nil
        await #expect(throws: ExpansionError.inputCancelled) { try await run("#{input:Name}", ctx) }
    }

    @Test func cursorMovesLeft() async throws {
        #expect(try await run("ab#{cursor}cd#{cursor}") == [.paste("abcd"), .moveLeft(2)])
    }

    @Test func cursorCountsCharacters() async throws {
        #expect(try await run("a#{cursor}👍🏽é") == [.paste("a👍🏽é"), .moveLeft(2)])
    }

    @Test func cursorInsideComboCounts() async throws {
        let ctx = FakeContext()
        ctx.snippets = [snip(";c", "x#{cursor}y")]
        #expect(try await run("#{combo:;c}z#{cursor}", ctx) == [.paste("xyz"), .moveLeft(2)])
    }

    @Test func cursorIgnoredWhenStepsFollow() async throws {
        #expect(try await run("a#{cursor}b#{key:tab}") == [.paste("ab"), .key(.tab, count: 1)])
    }

    @Test func keysShortcutsDelaysActions() async throws {
        let steps = try await run("a#{key:tab:3}b#{shortcut:Cmd+Shift+J}#{delay:500}#{openApp:/X.app}#{runShortcut:Foo}c")
        let combo = KeyCombo(command: true, option: false, control: false, shift: true, keyCode: CGKeyCode(kVK_ANSI_J))
        #expect(steps == [
            .paste("a"), .key(.tab, count: 3), .paste("b"), .shortcut(combo), .delay(milliseconds: 500),
            .openApp(path: "/X.app"), .runShortcut(name: "Foo"), .paste("c"),
        ])
    }

    @Test func keyComboParsing() {
        #expect(KeyCombo.parse("Control+Option+f12") == KeyCombo(
            command: false, option: true, control: true, shift: false, keyCode: CGKeyCode(kVK_F12)))
        #expect(KeyCombo.parse("Cmd+1")?.keyCode == CGKeyCode(kVK_ANSI_1))
        #expect(KeyCombo.parse("Ctrl+J") == nil)
        #expect(KeyCombo.parse("Cmd+") == nil)
        #expect(KeyCombo.parse("Cmd+JK") == nil)
    }

    @Test func unknownOrInvalidLeftLiteral() async throws {
        let src = "#{nope} #{key:bogus} #{delay:-5} #{dateTime:+1x:} #{key:tab:0} #{shortcut:Hyper+J} #{cursor:x} #{combo:}"
        #expect(try await run(src) == [.paste(src)])
    }

    @Test func envVar() async throws {
        let ctx = FakeContext()
        ctx.env = ["HOME": "/Users/x"]
        #expect(try await run("#{envVar:HOME}|#{envVar:NOPE}", ctx) == [.paste("/Users/x|")])
    }

    @Test func shellTimeoutsAndTrim() async throws {
        let ctx = FakeContext()
        ctx.scriptResult = .success("out\n")
        #expect(try await run("[#{shell:/s.sh:2500}][#{shell:/s.sh}]", ctx) == [.paste("[out][out]")])
        #expect(ctx.scriptCalls == ["/s.sh 2500", "/s.sh 10000"])
        ctx.scriptResult = .failure(.scriptTimedOut(path: "/s.sh"))
        await #expect(throws: ExpansionError.scriptTimedOut(path: "/s.sh")) { try await run("#{shell:/s.sh}", ctx) }
    }

    @Test func messagesAreOneLine() {
        let errors: [ExpansionError] = [
            .missingCombo(";zz"), .scriptNotFound(path: "/s"), .scriptFailed(path: "/s", status: 1),
            .scriptTimedOut(path: "/s"), .inputCancelled, .appNotFound(path: "/A.app"), .unknownShortcut("F"),
            .shortcutFailed(name: "F", status: 2), .shortcutTimedOut("F"), .targetAppChanged,
        ]
        for e in errors { #expect(!e.message.isEmpty && !e.message.contains("\n")) }
        #expect(ExpansionError.missingCombo(";zz").message == "No snippet has the keyword “;zz”.")
    }
}
