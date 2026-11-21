import Testing
@testable import xpnd

private func parse(_ source: String) -> Result<Variable, VariableProblem>? {
    guard case let .variable(name, argument, _)? = Template.parse(source).first else { return nil }
    return Variable.parse(name: name, argument: argument)
}

private func value(_ source: String) -> Variable? {
    guard case .success(let v)? = parse(source) else { return nil }
    return v
}

private func problem(_ source: String) -> String? {
    guard case .failure(let p)? = parse(source) else { return nil }
    return p.message
}

struct VariableTests {
    @Test func parsesEveryVariable() {
        #expect(value("#{clipboard}") == .clipboard(nil))
        #expect(value("#{clipboard:trim}") == .clipboard(.trim))
        #expect(value("#{selection:upper}") == .selection(.upper))
        #expect(value("#{date}") == .date(shift: nil))
        #expect(value("#{date:+1d}") == .date(shift: "+1d"))
        #expect(value("#{time:-2h}") == .time(shift: "-2h"))
        #expect(value("#{dateTime}") == .dateTime(shift: nil, format: ""))
        #expect(value("#{dateTime:HH:mm}") == .dateTime(shift: nil, format: "HH:mm"))
        #expect(value("#{dateTime:+1d:yyyy}") == .dateTime(shift: "+1d", format: "yyyy"))
        #expect(value("#{combo:;a}") == .snippet(keyword: ";a", .plain))
        #expect(value("#{upper:;a}") == .snippet(keyword: ";a", .upper))
        #expect(value("#{lower:;a}") == .snippet(keyword: ";a", .lower))
        #expect(value("#{cursor}") == .cursor)
        #expect(value("#{input:Name}") == .input(label: "Name", default: ""))
        #expect(value("#{choice:Size:S|M|L}") == .choice(label: "Size", options: ["S", "M", "L"]))
        #expect(value("#{longInput:Notes}") == .longInput(label: "Notes"))
        #expect(value("#{envVar:HOME}") == .envVar("HOME"))
        #expect(value("#{shell:/s.sh}") == .script(path: "/s.sh", timeoutMs: nil))
        #expect(value("#{shell:/s.sh:2500}") == .script(path: "/s.sh", timeoutMs: 2500))
        #expect(value("#{key:tab}") == .key(.tab, count: 1))
        #expect(value("#{key:tab:3}") == .key(.tab, count: 3))
        #expect(value("#{shortcut:Cmd+J}") == .shortcut("Cmd+J"))
        #expect(value("#{delay:500}") == .delay(500))
        #expect(value("#{openApp:/X.app}") == .openApp("/X.app"))
        #expect(value("#{runShortcut:Foo}") == .runShortcut("Foo"))
        #expect(value("#{uuid}") == .uuid)
        #expect(value("#{fullName}") == .fullName)
    }

    @Test func templateRoundTripsThroughParse() {
        let values: [Variable] = [
            .clipboard(nil), .clipboard(.lower), .selection(nil), .date(shift: nil), .time(shift: "+2h"),
            .dateTime(shift: nil, format: ""), .dateTime(shift: "-1w", format: "yyyy-MM-dd"), .dateTime(shift: nil, format: #"a}b\c"#),
            .snippet(keyword: ";x}", .upper), .cursor, .input(label: "Name", default: #"a}b\"#), .choice(label: "S", options: ["a", "b"]),
            .longInput(label: "L"), .envVar("HOME"), .script(path: "/s.sh", timeoutMs: nil), .script(path: "/a b/s.sh", timeoutMs: 50),
            .key(.f5, count: 1), .key(.left, count: 4), .shortcut("Cmd+Shift+J"), .delay(0), .openApp("/Applications/X.app"),
            .runShortcut("Make }"), .uuid, .fullName,
        ]
        for v in values {
            #expect(value(v.template) == v, "\(v.template)")
        }
    }

    @Test func scriptPathEndingInDigitsKeepsItsPath() {
        let v = Variable.script(path: "/bin/x:5", timeoutMs: nil)
        #expect(value(v.template) == .script(path: "/bin/x:5", timeoutMs: Variable.defaultScriptTimeoutMs))
    }

    @Test func inputDefaultSplitsAtFirstEquals() {
        #expect(value("#{input:Name=Jo=e}") == .input(label: "Name", default: "Jo=e"))
        #expect(value("#{input:Name=}") == .input(label: "Name", default: ""))
    }

    @Test func choiceSplitsOptionsOnBar() {
        #expect(value("#{choice:Pick one:a b|c:d}") == .choice(label: "Pick one", options: ["a b", "c:d"]))
        #expect(problem("#{choice:Size}") != nil)
        #expect(problem("#{choice:Size:a||b}") != nil)
        #expect(problem("#{choice::a|b}") != nil)
    }

    @Test func problemsForUnknownNameAndBadArguments() {
        #expect(problem("#{nope}") == "xpnd has no variable “#{nope}”.")
        #expect(problem("#{key:tabb}") == "“tabb” isn't a key name.")
        #expect(problem("#{dateTime:+1x:yyyy}") == "“+1x” isn't a date shift, like +1d or -2h.")
        #expect(problem("#{delay:abc}") == "“abc” isn't a number of milliseconds.")
        #expect(problem("#{input}") == "Input needs a label.")
        #expect(problem("#{date:x}") == "“x” isn't a date shift, like +1d or -2h.")
        #expect(problem("#{clipboard:shout}") == "“shout” isn't trim, upper or lower.")
        #expect(problem("#{cursor:x}") == "#{cursor} takes nothing after a colon.")
        #expect(problem("#{key:tab:0}") != nil)
        #expect(problem("#{shortcut:Hyper+J}") != nil)
        #expect(problem("#{combo:}") != nil)
        #expect(problem("#{delay:-5}") != nil)
    }
}
