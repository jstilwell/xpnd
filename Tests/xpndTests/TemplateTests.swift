import Testing
@testable import xpnd

struct TemplateTests {
    @Test func plainText() {
        #expect(Template.parse("hi") == [.text("hi")])
    }

    @Test func simpleVariable() {
        #expect(Template.parse("a#{date}b") == [
            .text("a"), .variable(name: "date", argument: nil, raw: "#{date}"), .text("b"),
        ])
    }

    @Test func argumentKeepsColons() {
        #expect(Template.parse("#{dateTime:HH:mm}") == [
            .variable(name: "dateTime", argument: "HH:mm", raw: "#{dateTime:HH:mm}"),
        ])
    }

    @Test func escapesInArgument() {
        let src = #"#{input:a\}b\\c}"#
        #expect(Template.parse(src) == [.variable(name: "input", argument: #"a}b\c"#, raw: src)])
    }

    @Test func unterminatedIsText() {
        #expect(Template.parse("x#{date") == [.text("x#{date")])
        #expect(Template.parse(#"#{input:a\}"#) == [.text(#"#{input:a\}"#)])
    }

    @Test func spaceInBracesIsText() {
        #expect(Template.parse("#{ date }") == [.text("#{ date }")])
    }

    @Test func adjacentTextMerges() {
        #expect(Template.parse("a#{ x }b") == [.text("a#{ x }b")])
    }

    @Test func backslashOutsideArgumentIsLiteral() {
        #expect(Template.parse(##"\#{date}\"##) == [
            .text(##"\"##), .variable(name: "date", argument: nil, raw: "#{date}"), .text(##"\"##),
        ])
    }

    @Test func emptyArgumentAndOtherBackslash() {
        #expect(Template.parse("#{input:}") == [.variable(name: "input", argument: "", raw: "#{input:}")])
        #expect(Template.parse(#"#{input:a\nb}"#) == [
            .variable(name: "input", argument: #"a\nb"#, raw: #"#{input:a\nb}"#),
        ])
    }
}
