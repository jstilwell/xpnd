import Foundation
import Testing
@testable import xpnd

struct VariableFormTests {
    @Test func everyKindsBlankRoundTrips() {
        for kind in VariableKind.allCases {
            #expect(VariableDraft(kind.blank).variable(kind) == kind.blank, "\(kind)")
            #expect(VariableKind(kind.blank) == kind, "\(kind)")
        }
    }

    @Test func draftRoundTripsRealValues() {
        let values: [Variable] = [
            .input(label: "Name", default: "Ann"), .choice(label: "Size", options: ["S", "M"]), .longInput(label: "Notes"),
            .clipboard(.trim), .selection(nil), .dateTime(shift: "+1d", format: "yyyy"), .date(shift: "-2w"), .time(shift: nil),
            .snippet(keyword: ";sig", .upper), .envVar("HOME"), .script(path: "/s.sh", timeoutMs: 500), .key(.tab, count: 3),
            .shortcut("Cmd+Shift+J"), .delay(250),
        ]
        for v in values {
            let kind = VariableKind(v)!
            let draft = VariableDraft(v)
            #expect(draft.variable(kind) == v, "\(v)")
            #expect(draft.problem(kind) == nil, "\(v)")
        }
    }

    @Test func formRefusesABarInAChoiceOption() {
        var draft = VariableDraft(.choice(label: "Size", options: ["S", "M|L"]))
        #expect(draft.problem(.choice) == "An option can't contain “|”.")
        draft.options = ["S", ""]
        #expect(draft.problem(.choice) == "A choice option is empty.")
        draft = VariableDraft(.choice(label: "a:b", options: ["S"]))
        #expect(draft.problem(.choice) == "A label can't contain “:”.")
        #expect(VariableDraft(.input(label: "a=b", default: "")).problem(.input) == "A label can't contain “=”.")
        #expect(VariableDraft(.input(label: "", default: "")).problem(.input) == "Input needs a label.")
    }

    @Test func escapesInFormValuesSurvive() {
        let v = Variable.input(label: "Path", default: #"C:\dir}x"#)
        #expect(VariableDraft(v).problem(.input) == nil)
        #expect(Template.variable(at: 3, in: v.template)?.variable == v)
    }

    @Test func shortcutDraftBuildsFromToggles() {
        var draft = VariableDraft(VariableKind.shortcut.blank)
        draft.command = true
        draft.option = true
        draft.shortcutKey = "tab"
        #expect(draft.variable(.shortcut) == .shortcut("Cmd+Option+tab"))
        #expect(draft.problem(.shortcut) == nil)
    }

    @Test func variablesWithoutAFormHaveNoKind() {
        for v: Variable in [.cursor, .uuid, .fullName, .openApp("/X.app"), .runShortcut("x")] {
            #expect(VariableKind(v) == nil)
        }
    }

    @Test func variableAtFindsTheTokenUnderTheCaret() {
        let text = "👍🏽 a#{key:tab}b"
        // 👍🏽 is 4 UTF-16 units, so the variable sits at 6..<16.
        let range = NSRange(location: 6, length: 10)
        #expect(Template.variable(at: 6, in: text)?.range == range)
        #expect(Template.variable(at: 10, in: text)?.variable == .key(.tab, count: 1))
        #expect(Template.variable(at: 15, in: text)?.range == range)
        #expect(Template.variable(at: 16, in: text) == nil)
        #expect(Template.variable(at: 5, in: text) == nil)
        #expect(Template.variable(at: 3, in: "a #{nope} b") == nil)
    }
}
