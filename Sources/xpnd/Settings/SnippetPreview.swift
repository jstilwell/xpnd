import SwiftUI

/// What the preview evaluates with. Dates, other snippets, `uuid`, `fullName` and transforms are real; it has no way to
/// read the clipboard, the selection or the environment, or to run a script, so those are labelled placeholders.
struct PreviewContext: EvaluationContext {
    let library: SnippetLibrary
    /// What was typed into the preview's fields, by label.
    let values: [String: String]
    let now = Date()
    let locale = Locale.current
    let timeZone = TimeZone.current
    let fullName = NSFullUserName()

    func clipboardText() async -> String? { "‹clipboard›" }
    func selectedText() async -> String? { "‹selection›" }
    func environment(_ name: String) -> String? { "‹\(name)›" }
    func snippet(keyword: String) -> Snippet? { library.snippet(keyword: keyword) }
    func runScript(path: String, timeoutMs: Int) async throws(ExpansionError) -> String { "‹output of \(path)›" }

    func askInputs(_ fields: [InputField]) async -> [String: String]? {
        Dictionary(fields.map { ($0.label, values[$0.label] ?? $0.kind.initialValue) }, uniquingKeysWith: { first, _ in first })
    }
}

extension InputField.Kind {
    /// What the field starts with: the default, or the first option.
    var initialValue: String {
        switch self {
        case .text(let def): def
        case .choice(let options): options.first ?? ""
        case .multiline: ""
        }
    }
}

enum PreviewText {
    static func evaluate(_ snippet: Snippet, library: SnippetLibrary, values: [String: String]) async -> Result<String, ExpansionError> {
        do throws(ExpansionError) {
            return .success(render(try await Evaluator.evaluate(snippet, context: PreviewContext(library: library, values: values))))
        } catch {
            return .failure(error)
        }
    }

    /// Text as it is; keys and actions as labels, never run; the cursor as ‸.
    static func render(_ steps: [PlayStep]) -> String {
        var out = ""
        for step in steps {
            switch step {
            case .paste(let s): out += s
            case let .key(key, count): out += "⟨\(name(key))\(count > 1 ? " ×\(count)" : "")⟩"
            case .shortcut(let c):
                let mods = (c.command ? "⌘" : "") + (c.option ? "⌥" : "") + (c.control ? "⌃" : "") + (c.shift ? "⇧" : "")
                let key = KeyCombo.keyText(c.keyCode).map { KeyName(rawValue: $0).map(name) ?? $0 } ?? "?"
                out += "⟨\(mods)\(key)⟩"
            case .delay(let ms): out += "⟨wait \(ms) ms⟩"
            case .openApp(let path):
                out += "⟨open \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)⟩"
            case .runShortcut(let n): out += "⟨run Shortcut “\(n)”⟩"
            case .moveLeft(let n):
                // Evaluator ends with this only after text, so the caret sits n characters before the end.
                let at = out.index(out.endIndex, offsetBy: -min(n, out.count))
                out.insert("‸", at: at)
            }
        }
        return out
    }

    private static func name(_ key: KeyName) -> String {
        switch key {
        case .tab: "Tab"
        case .enter: "Return"
        case .space: "Space"
        case .delete: "Delete"
        case .forwardDelete: "Forward Delete"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .escape: "Esc"
        default: key.rawValue.uppercased() // f1…f20
        }
    }
}

/// Under the snippet text: a field per input, then what the snippet will type. It follows the saved text, which saves
/// once typing pauses, so that pause is the preview's too.
struct SnippetPreview: View {
    let snippet: Snippet
    let library: SnippetLibrary
    @State private var values: [String: String] = [:]
    @State private var output: Result<String, ExpansionError>?

    private var fields: [InputField] {
        (try? Evaluator.inputFields(snippet, context: PreviewContext(library: library, values: [:]))) ?? []
    }

    var body: some View {
        Section("Preview") {
            ForEach(fields, id: \.label) { field in
                let value = Binding(get: { values[field.label] ?? field.kind.initialValue }, set: { values[field.label] = $0 })
                switch field.kind {
                case .text: TextField(field.label, text: value)
                case .choice(let options):
                    Picker(field.label, selection: value) { ForEach(options, id: \.self) { Text($0).tag($0) } }
                case .multiline: TextField(field.label, text: value, axis: .vertical).lineLimit(2...4)
                }
            }
            Group {
                switch output {
                case .success(let text)?:
                    Text(text.isEmpty ? " " : text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                case .failure(let error)?:
                    Text(error.message).foregroundStyle(.red)
                case nil:
                    Text(" ")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Preview")
        }
        .task(id: PreviewInput(text: snippet.text, values: values, library: library)) {
            output = await PreviewText.evaluate(snippet, library: library, values: values)
        }
        .onChange(of: snippet.id) { values = [:] }
    }
}

private struct PreviewInput: Equatable {
    let text: String
    let values: [String: String]
    let library: SnippetLibrary
}
