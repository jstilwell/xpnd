import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One snippet's fields. `edit` saves at once and returns false if the store refused the change.
struct SnippetEditorView: View {
    let snippet: Snippet
    /// Keywords share one namespace with connection and folder activation strings.
    let namespace: KeywordNamespace
    let readOnly: Bool
    let edit: ((inout Snippet) -> Void) -> Bool

    /// Kept apart from the snippet so a keyword with a problem stays visible without being saved.
    @State private var keyword = ""
    @State private var keywordProblem: String?
    @State private var template = TemplateTextController()
    @State private var choosingShortcut = false

    /// A form open for a new variable (`range` nil) or one in the text.
    @State private var form: FormRequest?

    private struct FormRequest: Identifiable {
        let id = UUID()
        let variable: Variable
        let kind: VariableKind
        /// The variable's place and source text, when editing one.
        let range: NSRange?
        let raw: String
    }

    /// The Insert Variable menu: `nil` kind inserts `direct` as it is.
    private static let menuItems: [[(title: String, kind: VariableKind?, direct: Variable?)]] = [
        [("Input…", .input, nil), ("Choice…", .choice, nil), ("Long Input…", .longInput, nil)],
        [("Clipboard…", .clipboard, nil), ("Selected Text…", .selection, nil)],
        [("Date", nil, .date(shift: nil)), ("Time", nil, .time(shift: nil)), ("Date and Time…", .dateTime, nil),
         ("Date, Shifted…", .date, nil), ("Time, Shifted…", .time, nil)],
        [("Other Snippet…", .snippet, nil), ("Cursor Position", nil, .cursor), ("UUID", nil, .uuid), ("Full Name", nil, .fullName),
         ("Environment Variable…", .envVar, nil), ("Script Output…", .script, nil)],
        [("Key Press…", .key, nil), ("Keyboard Shortcut…", .shortcut, nil), ("Delay…", .delay, nil)],
    ]

    var body: some View {
        Form {
            CommittingTextField("Name", text: snippet.name) { name in _ = edit { $0.name = name } }.id(snippet.id)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Keyword", text: $keyword)
                    .commitsOnPause(keyword, saveKeyword)
                if let keywordProblem {
                    Text(keywordProblem).font(.callout).foregroundStyle(.red)
                } else if let note = namespace.hidingNote(keyword, for: .snippet(snippet.id)) {
                    Text(note).font(.callout).foregroundStyle(.orange)
                }
            }
            Picker("Matching", selection: binding(\.matching)) {
                Text("Strict: typed on its own").tag(MatchingMode.strict)
                Text("Loose: even right after other text").tag(MatchingMode.loose)
            }
            Toggle("Enabled", isOn: binding(\.enabled))
            Section {
                TemplateTextView(text: snippet.text, snippetID: snippet.id, isEditable: !readOnly, controller: template,
                                 check: { [keyword = snippet.keyword, library = namespace.snippets] in
                                     TemplateCheck.marks(in: $0, keyword: keyword, library: library)
                                 },
                                 editVariable: { range, raw, variable in
                                     guard let kind = VariableKind(variable) else { return }
                                     form = FormRequest(variable: variable, kind: kind, range: range, raw: raw)
                                 }) { new in
                    edit { $0.text = new }
                }
                    .frame(minHeight: 200)
            } header: {
                HStack {
                    Text("Text")
                    Spacer()
                    insertMenu
                }
            }
            SnippetPreview(snippet: snippet, library: namespace.snippets)
        }
        .formStyle(.grouped)
        .disabled(readOnly)
        .onAppear {
            keyword = snippet.keyword
            // An existing cross-file duplicate shows without typing.
            keywordProblem = namespace.problem(keyword, for: .snippet(snippet.id))
        }
        .onChange(of: snippet.id) {
            keyword = snippet.keyword
            keywordProblem = namespace.problem(keyword, for: .snippet(snippet.id))
        }
        // The check shows while typing; the save waits for a pause (`commitsOnPause`).
        .onChange(of: keyword) { keywordProblem = namespace.problem(keyword, for: .snippet(snippet.id)) }
        .sheet(item: $form) { request in
            VariableForm(variable: request.variable, kind: request.kind, library: namespace.snippets, editing: request.range != nil) { new in
                if let range = request.range {
                    template.replace(range, expected: request.raw, with: new.template)
                } else {
                    template.insert(new.template)
                }
            }
        }
        .sheet(isPresented: $choosingShortcut) {
            ShortcutChooser { template.insert(Variable.runShortcut($0).template) }
        }
    }

    private var insertMenu: some View {
        Menu("Insert Variable") {
            ForEach(Self.menuItems.indices, id: \.self) { section in
                ForEach(Self.menuItems[section], id: \.title) { item in
                    Button(item.title) {
                        if let kind = item.kind {
                            form = FormRequest(variable: kind.blank, kind: kind, range: nil, raw: "")
                        } else if let direct = item.direct {
                            template.insert(direct.template)
                        }
                    }
                }
                Divider()
            }
            Button("Open App…", action: chooseApp)
            Button("Run Shortcut…") { choosingShortcut = true }
        }
        .fixedSize()
    }

    private func binding<T>(_ key: WritableKeyPath<Snippet, T>) -> Binding<T> {
        Binding(get: { snippet[keyPath: key] }, set: { value in _ = edit { $0[keyPath: key] = value } })
    }

    private func saveKeyword() {
        keywordProblem = namespace.problem(keyword, for: .snippet(snippet.id))
        guard keywordProblem == nil, keyword != snippet.keyword else { return }
        let new = keyword
        // On failure the page-level message says why, and the field shows the saved keyword again.
        if !edit({ $0.keyword = new }) { keyword = snippet.keyword }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        template.insert(Variable.openApp(url.path(percentEncoded: false)).template)
    }
}

/// Lists the user's shortcuts from the Shortcuts app; picking one inserts it.
private struct ShortcutChooser: View {
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String]?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Run Shortcut").font(.headline)
            if let names {
                if names.isEmpty {
                    ContentUnavailableView("No Shortcuts Found", systemImage: "square.stack.3d.up")
                } else {
                    List(names, id: \.self) { name in
                        Button(name) {
                            choose(name)
                            dismiss()
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 360, height: 360)
        .task { names = await ShortcutsList.fetch() ?? [] }
    }
}
