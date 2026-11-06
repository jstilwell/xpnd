import SwiftUI

/// One RDP option. With `defaultValue`, an unset option shows "Default (…)" and a set one offers
/// "Use default"; without it (the global settings) the option is always set.
struct RDPOptionRow<Value: Equatable, Control: View>: View {
    let value: Binding<Value?>
    let defaultValue: Value?
    let describe: (Value) -> String
    @ViewBuilder let control: (Binding<Value>) -> Control

    var body: some View {
        HStack {
            control(Binding(get: { value.wrappedValue ?? defaultValue! }, set: { value.wrappedValue = $0 }))
            if let defaultValue {
                if value.wrappedValue == nil {
                    Text("Default (\(describe(defaultValue)))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Use default") { value.wrappedValue = nil }.controlSize(.small)
                }
            }
        }
    }
}

/// Every RDP option except the gateway, as `Section`s. Shared by the connection editor
/// (`defaults` set) and the Remote Desktop settings tab (`defaults` nil).
struct RDPFields: View {
    @Binding var options: RDPOptions
    var defaults: RDPSettings?

    var body: some View {
        let d = defaults
        Section("Display") {
            RDPOptionRow(value: $options.display, defaultValue: d?.display, describe: RDPOptionLabels.label(for:)) { DisplayPicker(display: $0) }
            // shortcut: 1:1 with scrolling not implemented (a fixed size is always scaled to fit, letterboxed),
            // upgrade with an NSScrollView host; `scaleToFit` stays in the model so YAML is stable.
            RDPOptionRow(value: $options.colorDepth, defaultValue: d?.colorDepth, describe: { "\($0)-bit" }) { depth in
                Picker("Color depth", selection: depth) { ForEach([32, 16], id: \.self) { Text("\($0)-bit").tag($0) } }
            }
            toggle("Retina resolution", \.retina, d?.retina)
        }
        Section("Sound & Clipboard") {
            RDPOptionRow(value: $options.audio, defaultValue: d?.audio, describe: RDPOptionLabels.label(for:)) { audio in
                Picker("Sound", selection: audio) {
                    ForEach([RDPOptions.Audio.local, .remote, .off], id: \.self) { Text(RDPOptionLabels.label(for: $0)).tag($0) }
                }
            }
            toggle("Share clipboard", \.clipboard, d?.clipboard)
            toggle("Share printers", \.printers, d?.printers)
        }
        Section("Files") {
            toggle("File drop drive", \.dropDrive, d?.dropDrive)
        }
        Section("Security") {
            toggle("Network Level Authentication", \.nla, d?.nla)
        }
        Section("Network") {
            RDPOptionRow(value: $options.performance, defaultValue: d?.performance, describe: RDPOptionLabels.label(for:)) { perf in
                Picker("Connection quality", selection: perf) {
                    ForEach([RDPOptions.Performance.auto, .lan, .broadband], id: \.self) { Text(RDPOptionLabels.label(for: $0)).tag($0) }
                }
            }
            number("Timeout (seconds)", \.timeoutSeconds, d?.timeoutSeconds)
            toggle("Reconnect automatically", \.autoReconnect, d?.autoReconnect)
            number("Reconnect tries", \.reconnectTries, d?.reconnectTries)
        }
        Section("Advanced") {
            toggle("Command key as Windows key", \.commandAsWindowsKey, d?.commandAsWindowsKey)
            toggle("Connect to console session", \.consoleSession, d?.consoleSession)
            RDPOptionRow(value: Binding(get: { options.alternateShell }, set: { options.alternateShell = $0?.isEmpty == true ? nil : $0 }),
                         defaultValue: d?.alternateShell, describe: { $0.isEmpty ? "None" : $0 }) { shell in
                TextField("Alternate shell", text: shell, prompt: Text("None"))
            }
        }
    }

    private func toggle(_ title: String, _ key: WritableKeyPath<RDPOptions, Bool?>, _ fallback: Bool?) -> some View {
        RDPOptionRow(value: $options[dynamicMember: key], defaultValue: fallback, describe: RDPOptionLabels.label(for:)) {
            Toggle(title, isOn: $0)
        }
    }

    /// Whole numbers of at least 1; anything else is ignored.
    private func number(_ title: String, _ key: WritableKeyPath<RDPOptions, Int?>, _ fallback: Int?) -> some View {
        RDPOptionRow(value: $options[dynamicMember: key], defaultValue: fallback, describe: { String($0) }) { number in
            TextField(title, value: Binding(get: { number.wrappedValue }, set: { number.wrappedValue = max(1, $0) }), format: .number)
        }
    }
}

/// The display presets plus Custom… with width and height.
private struct DisplayPicker: View {
    @Binding var display: RDPOptions.Display

    /// Custom is a size that isn't a preset, so it can't go stale when the value is reset.
    private var isCustom: Bool { !RDPOptionLabels.presets.contains(display) }

    var body: some View {
        Picker("Display", selection: Binding<RDPOptions.Display?>(get: { isCustom ? nil : display }, set: { choice in
            // Custom… seeds a non-preset size so its fields appear.
            display = choice ?? .fixed(width: 1600, height: 900)
        })) {
            ForEach(RDPOptionLabels.presets, id: \.self) { Text(RDPOptionLabels.label(for: $0)).tag(Optional($0)) }
            Divider()
            Text("Custom…").tag(Optional<RDPOptions.Display>.none)
        }
        if isCustom, case .fixed(let w, let h) = display {
            TextField("Width", value: Binding(get: { w }, set: { display = .fixed(width: max(1, $0), height: h) }), format: .number)
            TextField("Height", value: Binding(get: { h }, set: { display = .fixed(width: w, height: max(1, $0)) }), format: .number)
        }
    }
}

extension RDPSettings {
    /// The settings as fully-set options, so `RDPFields` edits both the same way.
    var asOptions: RDPOptions {
        get {
            RDPOptions(display: display, scaleToFit: scaleToFit, colorDepth: colorDepth, retina: retina, clipboard: clipboard,
                       audio: audio, printers: printers, commandAsWindowsKey: commandAsWindowsKey, nla: nla,
                       timeoutSeconds: timeoutSeconds, autoReconnect: autoReconnect, reconnectTries: reconnectTries,
                       performance: performance, alternateShell: alternateShell, consoleSession: consoleSession, dropDrive: dropDrive)
        }
        set {
            display = newValue.display ?? display
            scaleToFit = newValue.scaleToFit ?? scaleToFit
            colorDepth = newValue.colorDepth ?? colorDepth
            retina = newValue.retina ?? retina
            clipboard = newValue.clipboard ?? clipboard
            audio = newValue.audio ?? audio
            printers = newValue.printers ?? printers
            commandAsWindowsKey = newValue.commandAsWindowsKey ?? commandAsWindowsKey
            nla = newValue.nla ?? nla
            timeoutSeconds = newValue.timeoutSeconds ?? timeoutSeconds
            autoReconnect = newValue.autoReconnect ?? autoReconnect
            reconnectTries = newValue.reconnectTries ?? reconnectTries
            performance = newValue.performance ?? performance
            alternateShell = newValue.alternateShell ?? ""
            consoleSession = newValue.consoleSession ?? consoleSession
            dropDrive = newValue.dropDrive ?? dropDrive
        }
    }
}
