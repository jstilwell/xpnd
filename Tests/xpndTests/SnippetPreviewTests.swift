import Carbon.HIToolbox
import Foundation
import Testing
@testable import xpnd

private func preview(_ text: String, _ others: [Snippet] = [], values: [String: String] = [:]) async -> Result<String, ExpansionError> {
    let library = SnippetLibrary(groups: [SnippetGroup(name: "G", snippets: others)])
    return await PreviewText.evaluate(Snippet(name: "t", keyword: ";t", text: text), library: library, values: values)
}

struct SnippetPreviewTests {
    /// The context has no clipboard, environment or script runner to reach, so placeholders are all it can give.
    @Test func previewPlaceholdersForClipboardSelectionEnvAndScript() async {
        let nested = Snippet(name: "n", keyword: ";n", text: "#{shell:/x.sh}#{envVar:PATH}")
        let out = await preview("#{clipboard}|#{selection:upper}|#{envVar:HOME}|#{shell:/s.sh:50}|#{combo:;n}", [nested])
        #expect(out == .success("‹clipboard›|‹SELECTION›|‹HOME›|‹output of /s.sh›|‹output of /x.sh›‹PATH›"))
    }

    @Test func previewRendersKeysShortcutsDelaysAndActions() {
        let combo = KeyCombo(command: true, option: false, control: false, shift: true, keyCode: CGKeyCode(kVK_ANSI_J))
        let steps: [PlayStep] = [
            .paste("a"), .key(.tab, count: 1), .key(.down, count: 3), .shortcut(combo), .delay(milliseconds: 500),
            .openApp(path: "/Applications/Safari.app"), .runShortcut(name: "Make"), .paste("b"),
        ]
        #expect(PreviewText.render(steps) == "a⟨Tab⟩⟨↓ ×3⟩⟨⌘⇧J⟩⟨wait 500 ms⟩⟨open Safari⟩⟨run Shortcut “Make”⟩b")
    }

    @Test func previewShowsTheCursorMarker() async {
        #expect(await preview("ab#{cursor}c👍🏽") == .success("ab‸c👍🏽"))
    }

    @Test func previewUsesTypedValuesThenDefaults() async {
        let out = await preview("#{input:Name=Ann} #{choice:Size:S|M} #{longInput:Notes}.", values: ["Notes": "hi"])
        #expect(out == .success("Ann S hi."))
        #expect(await preview("#{input:Name=Ann}", values: ["Name": "Bo"]) == .success("Bo"))
    }

    @Test func previewShowsTheErrorMessage() async {
        let out = await preview("#{combo:;zz}")
        #expect(out == .failure(.missingCombo(";zz")))
    }

    @Test func previewDatesAndUUIDAreReal() async throws {
        let out = try await preview("#{uuid}").get()
        #expect(out.count == 36 && !out.contains("‹"))
    }
}
