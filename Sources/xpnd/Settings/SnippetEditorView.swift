import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One snippet's fields. `edit` saves at once and returns false if the store refused the change.
struct SnippetEditorView: View {
    let snippet: Snippet
    let library: SnippetLibrary
    let readOnly: Bool
    let edit: ((inout Snippet) -> Void) -> Bool

    /// Kept apart from the snippet so a keyword with a problem stays visible without being saved.
    @State private var keyword = ""
    @State private var keywordProblem: String?
    @State private var template = TemplateTextController()
    @State private var choosingShortcut = false

    /// Every variable in the spec's table, as the template it inserts.
    private static let variables: [(title: String, template: String)] = [
        ("Clipboard", "#{clipboard}"),
        ("Date", "#{date}"),
        ("Time", "#{time}"),
        ("Date and Time", "#{dateTime}"),
        ("Date and Time, Custom Format", "#{dateTime:yyyy-MM-dd}"),
        ("Date and Time, Shifted", "#{dateTime:+1d:yyyy-MM-dd}"),
        ("Other Snippet", "#{combo:;keyword}"),
        ("Other Snippet, Uppercased", "#{upper:;keyword}"),
        ("Other Snippet, Lowercased", "#{lower:;keyword}"),
        ("Cursor Position", "#{cursor}"),
        ("Input Prompt", "#{input:Label}"),
        ("Environment Variable", "#{envVar:HOME}"),
        ("Script Output", "#{shell:/path/to/script}"),
        ("Key Press", "#{key:tab}"),
        ("Keyboard Shortcut", "#{shortcut:Cmd+Shift+J}"),
        ("Delay", "#{delay:500}"),
    ]

    var body: some View {
        Form {
            TextField("Name", text: binding(\.name))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Keyword", text: $keyword)
                if let keywordProblem {
                    Text(keywordProblem).font(.callout).foregroundStyle(.red)
                }
            }
            Picker("Matching", selection: binding(\.matching)) {
                Text("Strict: typed on its own").tag(MatchingMode.strict)
                Text("Loose: even right after other text").tag(MatchingMode.loose)
            }
            Toggle("Enabled", isOn: binding(\.enabled))
            Section {
                TemplateTextView(text: binding(\.text), isEditable: !readOnly, controller: template)
                    .frame(minHeight: 200)
            } header: {
                HStack {
                    Text("Text")
                    Spacer()
                    insertMenu
                }
            }
        }
        .formStyle(.grouped)
        .disabled(readOnly)
        .onAppear { keyword = snippet.keyword }
        .onChange(of: snippet.id) {
            keyword = snippet.keyword
            keywordProblem = nil
        }
        .onChange(of: keyword) { saveKeyword() }
        .sheet(isPresented: $choosingShortcut) {
            ShortcutChooser { insert("runShortcut", $0) }
        }
    }

    private var insertMenu: some View {
        Menu("Insert Variable") {
            ForEach(Self.variables, id: \.template) { variable in
                Button("\(variable.title)   \(variable.template)") { template.insert(variable.template) }
            }
            Divider()
            Button("Open App…", action: chooseApp)
            Button("Run Shortcut…") { choosingShortcut = true }
        }
        .fixedSize()
    }

    private func binding<T>(_ key: WritableKeyPath<Snippet, T>) -> Binding<T> {
        Binding(get: { snippet[keyPath: key] }, set: { value in _ = edit { $0[keyPath: key] = value } })
    }

    private func saveKeyword() {
        keywordProblem = library.keywordProblem(keyword, for: snippet.id)
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
        insert("openApp", url.path(percentEncoded: false))
    }

    /// Inserts `#{name:argument}`, escaping `\` and `}` as the template syntax needs.
    private func insert(_ name: String, _ argument: String) {
        let escaped = argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "}", with: "\\}")
        template.insert("#{\(name):\(escaped)}")
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
        .task { names = await ShortcutsList.fetch() }
    }
}
