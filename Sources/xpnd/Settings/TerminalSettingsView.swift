import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Which apps count as a terminal, and what connecting does when none is in front. Saves at once.
struct TerminalSettingsView: View {
    @Bindable var settings: AppSettings
    @State private var selection: Set<String> = []
    @State private var addProblem: String?
    /// The custom template being typed; saved on Return or leaving the field, and only without a problem.
    @State private var template = ""
    @FocusState private var editingTemplate: Bool
    /// Local, so Custom can be chosen before its template is runnable.
    @State private var mode = Mode.preset(.terminal, newTab: false)

    /// A Picker tag: the custom template lives in `template`, not here.
    private enum Mode: Hashable {
        case preset(TerminalPreset, newTab: Bool), custom, builtIn
    }

    private static let modes: [Mode] = [.builtIn] + TerminalPreset.allCases.flatMap { preset in
        [Mode.preset(preset, newTab: false)] + (preset.supportsTabs ? [.preset(preset, newTab: true)] : [])
    } + [.custom]

    var body: some View {
        Form {
            Section {
                List(settings.terminal.terminalBundleIDs, id: \.self, selection: $selection) { id in
                    VStack(alignment: .leading) {
                        Text(Self.appName(id) ?? id)
                        Text(id).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 150)
                HStack {
                    Button("Add App…", action: addApp)
                    Button("Remove", action: { settings.terminal.terminalBundleIDs.removeAll { selection.contains($0) } })
                        .disabled(selection.isEmpty)
                }
                if let addProblem { Text(addProblem).font(.callout).foregroundStyle(.red) }
            } header: {
                Text("Terminal apps")
            } footer: {
                Text("When one of these is in front, connecting types the command into it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("When no terminal is in front") {
                Picker("Open in", selection: $mode) {
                    ForEach(Self.modes, id: \.self) { Text(Self.label($0)).tag($0) }
                }
                .onChange(of: mode) { save() }
                if mode == .custom {
                    TextField("Command", text: $template, prompt: Text("tmux new-window {command}"))
                        .font(.body.monospaced())
                        .focused($editingTemplate)
                        .onSubmit(save)
                        // Not on each keystroke, which would save every valid prefix on the way.
                        .onChange(of: editingTemplate) { if !editingTemplate { save() } }
                    if let problem = templateProblem {
                        Text(problem + " Not saved until it's valid; xpnd keeps using your previous choice.")
                            .font(.callout).foregroundStyle(.red)
                    }
                    Text("""
                        Runs with /bin/sh. {command} is inserted already quoted, so leave it outside quotes. \
                        Examples: tmux new-window {command} · alacritty -e sh -c {command}
                        Warp: use a custom command.
                        """)
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section {
                Picker("Font", selection: $settings.builtInTerminal.fontName) {
                    Text("System").tag(String?.none)
                    ForEach(Self.monospacedFamilies, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Stepper("Size: \(Int(settings.builtInTerminal.fontSize))", value: $settings.builtInTerminal.fontSize, in: 9...24)
                Picker("Colours", selection: $settings.builtInTerminal.scheme) {
                    Text("System").tag(BuiltInTerminalSettings.Scheme.system)
                    Text("Light").tag(BuiltInTerminalSettings.Scheme.light)
                    Text("Dark").tag(BuiltInTerminalSettings.Scheme.dark)
                }
                Picker("Cursor", selection: $settings.builtInTerminal.cursor) {
                    Text("Block").tag(BuiltInTerminalSettings.Cursor.block)
                    Text("Bar").tag(BuiltInTerminalSettings.Cursor.bar)
                    Text("Underline").tag(BuiltInTerminalSettings.Cursor.underline)
                }
                Toggle("Blink", isOn: $settings.builtInTerminal.cursorBlinks)
                Stepper("Scrollback lines: \(settings.builtInTerminal.scrollback.formatted())",
                        value: $settings.builtInTerminal.scrollback, in: 1_000...100_000, step: 1_000)
            } header: {
                Text("Built-in terminal")
            } footer: {
                Text("Applies to new sessions.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear(perform: save)
        .onAppear {
            switch settings.terminal.whenNoTerminal {
            case .preset(let preset, let newTab): mode = .preset(preset, newTab: newTab && preset.supportsTabs)
            case .builtIn: mode = .builtIn
            case .custom(let saved):
                mode = .custom
                template = saved
            }
        }
    }

    /// Fixed-pitch family names, the values stored in `fontName`.
    private static let monospacedFamilies: [String] = Set(
        NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask)?.compactMap { NSFont(name: $0, size: 12)?.familyName } ?? []
    ).sorted()

    /// Empty counts as a problem, since it would run nothing but the command itself.
    private var templateProblem: String? {
        template.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Enter a command, like tmux new-window {command}." : LaunchPlanner.templateProblem(template)
    }

    /// A template with a problem is never saved.
    private func save() {
        let action: NoTerminalAction
        switch mode {
        case .preset(let preset, let newTab): action = .preset(preset, newTab: newTab)
        case .builtIn: action = .builtIn
        case .custom:
            guard templateProblem == nil else { return }
            action = .custom(template: template)
        }
        if settings.terminal.whenNoTerminal != action { settings.terminal.whenNoTerminal = action }
    }

    private static func label(_ mode: Mode) -> String {
        switch mode {
        case .preset(let preset, let newTab): "\(preset.displayName), \(newTab ? "new tab" : "new window")"
        case .builtIn: "xpnd (built-in)"
        case .custom: "Custom command"
        }
    }

    private static func appName(_ bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(filePath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addProblem = nil
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else {
                addProblem = "\(url.lastPathComponent) has no bundle ID, so xpnd can't recognize it."
                continue
            }
            if !settings.terminal.terminalBundleIDs.contains(id) { settings.terminal.terminalBundleIDs.append(id) }
        }
    }
}
