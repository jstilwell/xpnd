import AppKit
import SwiftUI

/// What a key press means in the quick menu.
enum QuickMenuKey: Equatable {
    case pick(Int), up, down, choose, back, close
    /// ⌘ held: the same pick, connecting with sudo.
    case pickSudo(Int), chooseSudo

    /// Whether the panel eats a key press; Command, Control and Option presses go on to the system.
    static func swallows(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// nil for anything else. With ⌘ alone, only picks (digits, Return) map, as sudo picks; any other
    /// modifier combination is the system's.
    static func key(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> QuickMenuKey? {
        if modifiers.intersection([.command, .control, .option]) == [.command] {
            if keyCode == 36 || keyCode == 76 { return .chooseSudo }
            guard characters.count == 1, let n = Int(characters), (1...9).contains(n) else { return nil }
            return .pickSudo(n)
        }
        guard swallows(modifiers: modifiers) else { return nil }
        switch keyCode {
        case 36, 76: return .choose // Return, keypad Enter
        case 53: return .close
        case 123: return .back
        case 125: return .down
        case 126: return .up
        default:
            guard characters.count == 1, let n = Int(characters), (1...9).contains(n) else { return nil }
            return .pick(n)
        }
    }
}

/// The menu's state, driven by the panel's key handler rather than SwiftUI focus.
@MainActor @Observable
final class QuickMenuState {
    var model: QuickMenuModel
    var highlighted = 0
    @ObservationIgnored let choose: (Connection.ID, _ sudo: Bool) -> Void
    @ObservationIgnored let cancel: () -> Void

    init(model: QuickMenuModel, choose: @escaping (Connection.ID, _ sudo: Bool) -> Void, cancel: @escaping () -> Void) {
        self.model = model
        self.choose = choose
        self.cancel = cancel
    }

    func handle(_ key: QuickMenuKey) {
        let rows = model.rows
        switch key {
        case .pick(let n): if let row = model.row(number: n) { pick(row) }
        case .up: highlighted = max(highlighted - 1, 0)
        case .down: highlighted = min(highlighted + 1, max(rows.count - 1, 0))
        case .choose: if highlighted < rows.count { pick(rows[highlighted]) }
        case .pickSudo(let n): if let row = model.row(number: n) { pick(row, sudo: true) }
        case .chooseSudo: if highlighted < rows.count { pick(rows[highlighted], sudo: true) }
        case .back: back()
        case .close: cancel()
        }
    }

    func pick(_ row: QuickMenuRow, sudo: Bool = false) {
        if let id = model.choose(row) { choose(id, sudo) } else { highlighted = 0 }
    }

    func back() {
        guard model.canGoBack else { return }
        model.back()
        highlighted = 0
    }
}

/// The numbered menu a folder's activation string opens: 1–9 connect, arrows and Return pick, ← goes back, Esc closes.
@MainActor
final class QuickMenuPanel: LauncherPanel {
    func show(
        folder: ConnectionFolder.ID,
        library: ConnectionLibrary,
        onOpenApp: @escaping () -> Void,
        connect: @escaping (Connection.ID, pid_t?, _ sudo: Bool) async -> Void
    ) {
        let state = QuickMenuState(
            model: QuickMenuModel(library: library, folder: folder),
            choose: { [weak self] id, sudo in
                guard let self else { return }
                close()
                // Guarded against the app that was in front when the panel opened, not whatever is in front after refocusing.
                let target = previousApp?.processIdentifier
                Task {
                    await self.refocusPrevious()
                    await connect(id, target, sudo)
                }
            },
            cancel: { [weak self] in self?.close() }
        )
        // A mapped key (including ⌘ picks) is handled; any other unmodified key is swallowed so nothing
        // beeps (the panel is key but has no text field); other modified keys are the system's.
        onKeyDown = { event in
            if let key = QuickMenuKey.key(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers ?? "", modifiers: event.modifierFlags
            ) {
                state.handle(key)
                return true
            }
            return QuickMenuKey.swallows(modifiers: event.modifierFlags)
        }
        present(QuickMenuView(state: state, openApp: { [weak self] in self?.close(); onOpenApp() }))
    }
}

private struct QuickMenuView: View {
    let state: QuickMenuState
    let openApp: () -> Void

    var body: some View {
        let model = state.model
        let rows = model.rows
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if model.canGoBack {
                    Button { state.back() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).accessibilityLabel("Back")
                }
                Text(model.title).font(.headline)
                Spacer()
                Text("⌘ for sudo").font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            Divider()
            if rows.isEmpty {
                VStack(spacing: 12) {
                    Text("No connections in \(model.title) yet").foregroundStyle(.secondary)
                    Button("Open xpnd", action: openApp)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Keeps the highlighted row in view, so Return never picks a row the user can't see.
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                                rowView(row, selected: index == state.highlighted)
                                    .id(index)
                                    .onTapGesture { state.pick(row, sudo: NSEvent.modifierFlags.contains(.command)) }
                            }
                        }
                    }
                    .onChange(of: state.highlighted) { proxy.scrollTo($1) }
                }
            }
        }
        .frame(width: 560, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func rowView(_ row: QuickMenuRow, selected: Bool) -> some View {
        let symbol: String, kind: String
        switch row.kind {
        case .connection(_, .ssh): (symbol, kind) = ("terminal", "ssh")
        case .connection(_, .vnc): (symbol, kind) = ("display", "vnc")
        case .folder: (symbol, kind) = ("folder", "folder")
        }
        return HStack(spacing: 10) {
            Text(row.number.map(String.init) ?? "").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Image(systemName: symbol).frame(width: 20).accessibilityHidden(true)
            Text(row.title).lineLimit(1).foregroundStyle(row.color?.ui ?? Color.primary)
            Spacer()
            if kind != "folder" { Text(kind).font(.callout.monospaced()).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.25) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([row.number.map { "\($0)" }, row.title, kind].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}
