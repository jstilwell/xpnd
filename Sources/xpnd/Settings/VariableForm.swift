import AppKit
import SwiftUI

/// The variables that have a form: its fields edit a `VariableDraft`. The rest (cursor, uuid, full name, plain date and
/// time) insert directly, and Open App and Run Shortcut keep their pickers.
enum VariableKind: CaseIterable, Hashable {
    case input, choice, longInput, clipboard, selection, dateTime, date, time, snippet, envVar, script, key, shortcut, delay

    init?(_ variable: Variable) {
        switch variable {
        case .input: self = .input
        case .choice: self = .choice
        case .longInput: self = .longInput
        case .clipboard: self = .clipboard
        case .selection: self = .selection
        case .dateTime: self = .dateTime
        case .date: self = .date
        case .time: self = .time
        case .snippet: self = .snippet
        case .envVar: self = .envVar
        case .script: self = .script
        case .key: self = .key
        case .shortcut: self = .shortcut
        case .delay: self = .delay
        case .cursor, .uuid, .fullName, .openApp, .runShortcut: return nil
        }
    }

    var title: String {
        switch self {
        case .input: "Input"
        case .choice: "Choice"
        case .longInput: "Long Input"
        case .clipboard: "Clipboard"
        case .selection: "Selected Text"
        case .dateTime: "Date and Time"
        case .date: "Date, Shifted"
        case .time: "Time, Shifted"
        case .snippet: "Other Snippet"
        case .envVar: "Environment Variable"
        case .script: "Script Output"
        case .key: "Key Press"
        case .shortcut: "Keyboard Shortcut"
        case .delay: "Delay"
        }
    }

    /// What a new one starts as.
    var blank: Variable {
        switch self {
        case .input: .input(label: "", default: "")
        case .choice: .choice(label: "", options: ["", ""])
        case .longInput: .longInput(label: "")
        case .clipboard: .clipboard(nil)
        case .selection: .selection(nil)
        case .dateTime: .dateTime(shift: nil, format: "yyyy-MM-dd")
        case .date: .date(shift: "+1d")
        case .time: .time(shift: "+1h")
        case .snippet: .snippet(keyword: "", .plain)
        case .envVar: .envVar("")
        case .script: .script(path: "", timeoutMs: nil)
        case .key: .key(.tab, count: 1)
        case .shortcut: .shortcut("")
        case .delay: .delay(500)
        }
    }
}

/// Every field any form edits, so a form can bind to plain properties.
struct VariableDraft: Equatable {
    var label = "", defaultValue = "", options: [String] = []
    var transform: Variable.Transform?
    var shift = "", format = ""
    var keyword = "", letterCase = Variable.Case.plain
    var name = "", path = "", timeoutMs: Int?
    var key = KeyName.tab, count = 1
    var command = false, option = false, control = false, shift_ = false, shortcutKey = ""
    var milliseconds = 0

    init(_ variable: Variable) {
        switch variable {
        case let .input(label, def): self.label = label; defaultValue = def
        case let .choice(label, options): self.label = label; self.options = options
        case .longInput(let label): self.label = label
        case .clipboard(let t), .selection(let t): transform = t
        case let .dateTime(shift, format): self.shift = shift ?? ""; self.format = format
        case .date(let shift), .time(let shift): self.shift = shift ?? ""
        case let .snippet(keyword, c): self.keyword = keyword; letterCase = c
        case .envVar(let name): self.name = name
        case let .script(path, timeout): self.path = path; timeoutMs = timeout
        case let .key(key, count): self.key = key; self.count = count
        case .shortcut(let s):
            var parts = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            shortcutKey = parts.popLast() ?? ""
            command = parts.contains("Cmd"); option = parts.contains("Option")
            control = parts.contains("Control"); shift_ = parts.contains("Shift")
        case .delay(let ms): milliseconds = ms
        case .cursor, .uuid, .fullName, .openApp, .runShortcut: break
        }
    }

    func variable(_ kind: VariableKind) -> Variable {
        func shiftOrNil() -> String? { shift.isEmpty ? nil : shift }
        switch kind {
        case .input: return .input(label: label, default: defaultValue)
        case .choice: return .choice(label: label, options: options)
        case .longInput: return .longInput(label: label)
        case .clipboard: return .clipboard(transform)
        case .selection: return .selection(transform)
        case .dateTime: return .dateTime(shift: shiftOrNil(), format: format)
        case .date: return .date(shift: shiftOrNil())
        case .time: return .time(shift: shiftOrNil())
        case .snippet: return .snippet(keyword: keyword, letterCase)
        case .envVar: return .envVar(name)
        case .script: return .script(path: path, timeoutMs: timeoutMs)
        case .key: return .key(key, count: count)
        case .shortcut:
            let mods = [(command, "Cmd"), (option, "Option"), (control, "Control"), (shift_, "Shift")].filter(\.0).map(\.1)
            return .shortcut((mods + [shortcutKey]).joined(separator: "+"))
        case .delay: return .delay(milliseconds)
        }
    }

    /// Why this can't be inserted: what the variable's own text would read back as, if not this.
    func problem(_ kind: VariableKind) -> String? {
        let variable = variable(kind)
        let tokens = Template.parse(variable.template)
        guard tokens.count == 1, case let .variable(name, argument, _) = tokens[0] else { return "This can't be written as a variable." }
        switch Variable.parse(name: name, argument: argument) {
        case .failure(let problem): return problem.message
        case .success(let back) where back == variable: return nil
        case .success:
            switch kind {
            case .input: return "A label can't contain “=”."
            case .choice where label.contains(":"): return "A label can't contain “:”."
            case .choice: return "An option can't contain “|”."
            case .dateTime: return "A format can't start with + or - and contain a colon; add a shift first."
            default: return "This can't be written as a variable."
            }
        }
    }
}

/// The sheet for one variable. `done` gets the variable to insert, or to put in place of the one being edited.
struct VariableForm: View {
    let kind: VariableKind
    let library: SnippetLibrary
    /// True when editing a variable already in the text.
    let editing: Bool
    let done: (Variable) -> Void
    @State private var draft: VariableDraft
    @State private var sample = ""
    @State private var keywordSearch = ""
    @Environment(\.dismiss) private var dismiss

    init(variable: Variable, kind: VariableKind, library: SnippetLibrary, editing: Bool, done: @escaping (Variable) -> Void) {
        self.kind = kind
        self.library = library
        self.editing = editing
        self.done = done
        _draft = State(initialValue: VariableDraft(variable))
    }

    private static let formats: [(String, String)] = [
        ("2026-11-21", "yyyy-MM-dd"), ("November 21, 2026", "MMMM d, yyyy"), ("Saturday", "EEEE"),
        ("14:05", "HH:mm"), ("2:05 PM", "h:mm a"), ("2026-11-21 14:05", "yyyy-MM-dd HH:mm"),
    ]

    var body: some View {
        let problem = draft.problem(kind)
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).font(.headline)
            Form { fields }
                .formStyle(.grouped)
            if [.dateTime, .date, .time].contains(kind) {
                LabeledContent("Sample", value: sample)
                    .task(id: draft) { sample = await sampleText() }
            }
            HStack {
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing ? "Save" : "Insert") {
                    done(draft.variable(kind))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding()
        .frame(width: 440)
    }

    @ViewBuilder private var fields: some View {
        switch kind {
        case .input:
            TextField("Label", text: $draft.label)
            TextField("Starts with", text: $draft.defaultValue, prompt: Text("Optional"))
        case .choice:
            TextField("Label", text: $draft.label)
            Section("Options (the first is preselected)") {
                ForEach(draft.options.indices, id: \.self) { i in
                    HStack {
                        TextField("Option \(i + 1)", text: $draft.options[i]).labelsHidden()
                        Button("Move Up", systemImage: "arrow.up") { draft.options.swapAt(i, i - 1) }
                            .disabled(i == 0).labelStyle(.iconOnly).buttonStyle(.borderless).help("Move up")
                        Button("Remove", systemImage: "minus.circle") { draft.options.remove(at: i) }
                            .disabled(draft.options.count <= 1).labelStyle(.iconOnly).buttonStyle(.borderless).help("Remove")
                    }
                }
                Button("Add Option", systemImage: "plus") { draft.options.append("") }
            }
        case .longInput:
            TextField("Label", text: $draft.label)
        case .clipboard, .selection:
            Picker("Change it", selection: $draft.transform) {
                Text("As it is").tag(Variable.Transform?.none)
                Text("Trim spaces and new lines").tag(Variable.Transform?.some(.trim))
                Text("UPPERCASE").tag(Variable.Transform?.some(.upper))
                Text("lowercase").tag(Variable.Transform?.some(.lower))
            }
            if kind == .selection {
                Text("Only from the picker: a typed keyword has already replaced any selection.").font(.callout).foregroundStyle(.secondary)
            }
        case .dateTime:
            Picker("Format", selection: $draft.format) {
                ForEach(Self.formats, id: \.1) { Text($0.0).tag($0.1) }
                if !Self.formats.contains(where: { $0.1 == draft.format }) { Text("Custom").tag(draft.format) }
            }
            TextField("Custom format", text: $draft.format, prompt: Text("yyyy-MM-dd"))
            shiftField
        case .date, .time:
            shiftField
        case .snippet:
            TextField("Search", text: $keywordSearch)
            Picker("Snippet", selection: $draft.keyword) {
                ForEach(keywords, id: \.self) { Text($0).tag($0) }
                if !keywords.contains(draft.keyword) { Text(draft.keyword.isEmpty ? "Choose…" : draft.keyword).tag(draft.keyword) }
            }
            Picker("Case", selection: $draft.letterCase) {
                Text("As written").tag(Variable.Case.plain)
                Text("UPPERCASE").tag(Variable.Case.upper)
                Text("lowercase").tag(Variable.Case.lower)
            }
        case .envVar:
            TextField("Name", text: $draft.name, prompt: Text("HOME"))
        case .script:
            HStack {
                TextField("Script", text: $draft.path, prompt: Text("/path/to/script"))
                Button("Choose…", action: chooseScript)
            }
            TextField("Timeout (ms)", value: $draft.timeoutMs, format: .number, prompt: Text("\(Variable.defaultScriptTimeoutMs)"))
        case .key:
            Picker("Key", selection: $draft.key) { ForEach(KeyName.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            Stepper("Times: \(draft.count)", value: $draft.count, in: 1...99)
        case .shortcut:
            Toggle("⌘ Command", isOn: $draft.command)
            Toggle("⌥ Option", isOn: $draft.option)
            Toggle("⌃ Control", isOn: $draft.control)
            Toggle("⇧ Shift", isOn: $draft.shift_)
            Picker("Key", selection: $draft.shortcutKey) {
                if draft.shortcutKey.isEmpty { Text("Choose…").tag("") }
                ForEach(Self.shortcutKeys, id: \.self) { Text($0).tag($0) }
            }
        case .delay:
            Stepper(value: $draft.milliseconds, in: 0...60_000, step: 100) {
                TextField("Milliseconds", value: $draft.milliseconds, format: .number)
            }
        }
    }

    private var shiftField: some View {
        TextField("Shift", text: $draft.shift, prompt: Text("+1d, -2h, +1w+3d"))
            .help("y years, M months, w weeks, d days, h hours, m minutes, s seconds")
    }

    private var keywords: [String] {
        let all = library.groups.flatMap(\.snippets).map(\.keyword).sorted()
        return keywordSearch.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(keywordSearch) }
    }

    private static let shortcutKeys: [String] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init) + KeyName.allCases.map(\.rawValue)

    private func sampleText() async -> String {
        let snippet = Snippet(name: "", keyword: "", text: draft.variable(kind).template)
        switch await PreviewText.evaluate(snippet, library: .empty, values: [:]) {
        case .success(let s): return s
        case .failure(let e): return e.message
        }
    }

    private func chooseScript() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.path = url.path(percentEncoded: false)
    }
}
