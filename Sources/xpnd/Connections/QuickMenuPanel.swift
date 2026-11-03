import AppKit
import SwiftUI

/// The numbered menu a folder's activation string opens: 1–9 connect, arrows and Return pick, ← goes back, Esc closes.
@MainActor
final class QuickMenuPanel: LauncherPanel {
    func show(
        folder: ConnectionFolder.ID,
        library: ConnectionLibrary,
        onOpenApp: @escaping () -> Void,
        connect: @escaping (Connection.ID, pid_t?) async -> Void
    ) {
        present(QuickMenuView(
            model: QuickMenuModel(library: library, folder: folder),
            choose: { [weak self] id in
                guard let self else { return }
                close()
                Task { await connect(id, await self.refocusPrevious()) }
            },
            openApp: { [weak self] in self?.close(); onOpenApp() },
            cancel: { [weak self] in self?.close() }
        ))
    }
}

private struct QuickMenuView: View {
    @State var model: QuickMenuModel
    let choose: (Connection.ID) -> Void
    let openApp: () -> Void
    let cancel: () -> Void
    @State private var highlighted = 0
    // No text field here, so the view itself takes focus to receive key presses.
    @FocusState private var focused: Bool

    var body: some View {
        let rows = model.rows
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if model.canGoBack {
                    Button { back() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).accessibilityLabel("Back")
                }
                Text(model.title).font(.headline)
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
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                            rowView(row, selected: index == highlighted)
                                .onTapGesture { pick(row) }
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(rows.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.return) { if highlighted < rows.count { pick(rows[highlighted]) }; return .handled }
        .onKeyPress(.leftArrow) { back(); return .handled }
        .onKeyPress(.escape) { cancel(); return .handled }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard let n = Int(press.characters), let row = model.row(number: n) else { return .handled }
            pick(row)
            return .handled
        }
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
            Text(row.title).lineLimit(1)
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

    private func pick(_ row: QuickMenuRow) {
        if let id = model.choose(row) { choose(id) } else { highlighted = 0 }
    }

    private func back() {
        model.back()
        highlighted = 0
    }
}
