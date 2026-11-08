import AppKit
import SwiftUI

/// The detail column while sessions are open: a row of tabs over the selected session's terminal.
struct TerminalWorkspace: View {
    let sessions: TerminalSessions
    let duplicate: (Connection.ID) -> Void
    /// Re-applied to every host on change.
    let settings: BuiltInTerminalSettings
    /// Writes a desktop's display choice to its connection (the notch's "Set as default").
    let saveDisplay: (Connection.ID, RDPOptions.Display) -> Bool
    /// A `.system` scheme is read when `apply` runs, so an appearance change re-applies too.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let session = sessions.selectedSession {
                // Per-session ids, so switching tabs swaps the view and the new one takes the keyboard.
                // A little room around the text; the margin matches the terminal's own background. A
                // desktop fills the tab, with its notch: inside the id, so a tab switch resets the hover.
                TerminalHostView(view: session.host.view)
                    .overlay(alignment: .top) { notch(session) }
                    .overlay(alignment: .top) {
                        if let offer = session.passwordOffer { offerBanner(offer, session) } else { copiedBanner(session) }
                    }
                    .id(session.id)
                    .padding(session.kind == .remoteDesktop ? 0 : 8)
                    .background(Color(nsColor: settings.colors.background))
                switch session.state {
                case .running: EmptyView()
                case .ended(let status):
                    endedBar(status.map { "Session ended (exit \($0))" } ?? "Session ended (signal)", session)
                case .disconnected(let reason):
                    endedBar("Disconnected: \(reason)", session, reconnect: true)
                }
            }
        }
        .background { shortcuts }
        .onChange(of: settings) { applySettings() }
        .onChange(of: colorScheme) { applySettings() }
    }

    @ViewBuilder private func notch(_ session: TerminalSession) -> some View {
        if let host = session.host as? RDPHost {
            RDPNotch(model: host.notch).onAppear { host.saveDisplay(to: session.connectionID, with: saveDisplay) }
        }
    }

    /// Ticks each second: the countdown, and it hides once the clipboard is cleared or copied over.
    @ViewBuilder private func copiedBanner(_ session: TerminalSession) -> some View {
        if let notice = session.copiedNotice {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = Int(notice.until.timeIntervalSince(context.date).rounded(.up))
                if left > 0, SecretClipboard.holdsSecret() {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill").foregroundStyle(.tint)
                        Text("\(notice.text) · ⌘V at the prompt · clears in \(left) s")
                        Button("Clear") {
                            SecretClipboard.clearIfOwned()
                            session.copiedNotice = nil
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 2)
                    .padding(.top, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// Send Password (⌘⇧P), or for an automatic offer a note that it goes in at the prompt.
    private func offerBanner(_ offer: PasswordOffer, _ session: TerminalSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(offer.until.timeIntervalSince(context.date).rounded(.up)))
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(.tint)
                    Text(offer.automatic
                         ? "\(offer.label) goes in at the next password prompt · \(left) s"
                         : "\(offer.label) ready · \(left) s")
                    Button(offer.automatic ? "Send Now" : "Send Password") {
                        offer.problem = offer.send(through: session.host) ? nil : "There's no password prompt at the cursor."
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    Button("Cancel") { offer.finish(sent: false) }
                }
                .controlSize(.small)
                if let problem = offer.problem { Text(problem).font(.callout).foregroundStyle(.red) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(radius: 2)
            .padding(.top, 6)
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(sessions.sessions) { tab($0) }
            }
            .padding(.horizontal, 6)
        }
        .padding(.vertical, 4)
    }

    private func tab(_ session: TerminalSession) -> some View {
        let isSelected = session.id == sessions.selected
        return HStack(spacing: 6) {
            Button { sessions.selected = session.id } label: {
                HStack(spacing: 6) {
                    Image(systemName: session.kind == .remoteDesktop ? "pc" : "terminal").foregroundStyle(.secondary)
                    Text(session.name).foregroundStyle(session.color?.ui ?? .primary).lineLimit(1)
                    if !session.isLive {
                        Text("ended").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            Button { close(session) } label: { Image(systemName: "xmark").font(.caption) }
                .accessibilityLabel("Close \(session.name)")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Duplicate") { duplicate(session.connectionID) }
            Button("Close") { close(session) }
        }
    }

    private func endedBar(_ text: String, _ session: TerminalSession, reconnect: Bool = false) -> some View {
        HStack {
            Text(text)
            Spacer()
            if reconnect { Button("Reconnect") { sessions.reconnect(session.id) } }
            Button("Close") { sessions.close(session.id) }
        }
        .padding(8)
        .background(.bar)
    }

    /// Hidden buttons, so the shortcuts beat the Window menu's ⌘W while tabs show (verified: a
    /// SwiftUI shortcut in the key window is offered before the main menu).
    private var shortcuts: some View {
        Group {
            Button("Close Tab") { sessions.shortcut { if let session = sessions.selectedSession { close(session) } } }
                .keyboardShortcut("w", modifiers: .command)
            // ⌘⇧] arrives as "}": SwiftUI never matches "]" with .shift.
            Button("Next Tab") { sessions.shortcut { cycle(1) } }.keyboardShortcut("}", modifiers: .command)
            Button("Previous Tab") { sessions.shortcut { cycle(-1) } }.keyboardShortcut("{", modifiers: .command)
            ForEach(1...9, id: \.self) { number in
                Button("Tab \(number)") {
                    sessions.shortcut {
                        if sessions.sessions.indices.contains(number - 1) { sessions.selected = sessions.sessions[number - 1].id }
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
            // Only on a desktop tab, so a terminal still receives ⌘⇧N. A real ⌘⇧N matches "n" with .shift, not "N".
            if let notch = (sessions.selectedSession?.host as? RDPHost)?.notch {
                Button("Toggle Notch") { sessions.shortcut { notch.isExpanded.toggle() } }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func cycle(_ step: Int) {
        let all = sessions.sessions
        guard let index = all.firstIndex(where: { $0.id == sessions.selected }) else { return }
        sessions.selected = all[(index + step + all.count) % all.count].id
    }

    private func close(_ session: TerminalSession) {
        guard session.isLive else { return sessions.close(session.id) }
        confirmTerminate(count: 1, in: session.host.view.window) { sessions.close(session.id) }
    }

    private func applySettings() {
        for session in sessions.sessions { session.host.apply(settings) }
    }
}

extension TerminalSessions {
    var selectedSession: TerminalSession? { sessions.first { $0.id == selected } }

    /// What every hidden shortcut runs through. It fires before the desktop's `performKeyEquivalent:`, so the
    /// selected tab must hear that ⌘ was used, or releasing it taps the Windows key.
    func shortcut(_ action: () -> Void) {
        selectedSession?.host.noteCommandUsed()
        action()
    }

    /// Gives the selected tab's terminal the keyboard.
    func focusSelected() {
        guard let view = selectedSession?.host.view else { return }
        view.window?.makeFirstResponder(view)
    }

    /// Takes the keyboard from the selected tab's terminal, if it has it.
    func resignFocus() {
        guard let view = selectedSession?.host.view, let window = view.window,
              (window.firstResponder as? NSView)?.isDescendant(of: view) == true else { return }
        window.makeFirstResponder(nil)
    }
}

/// "Terminate N sessions?" with Terminate / Cancel, as a sheet on `window` when there is one.
@MainActor func confirmTerminate(count: Int, in window: NSWindow?, then terminate: @escaping @MainActor () -> Void) {
    let alert = NSAlert()
    alert.messageText = TerminalSessions.terminateQuestion(count: count)
    alert.addButton(withTitle: "Terminate").hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel")
    guard let window else {
        if alert.runModal() == .alertFirstButtonReturn { terminate() }
        return
    }
    alert.beginSheetModal(for: window) { response in
        if response == .alertFirstButtonReturn { terminate() }
    }
}

/// Hosts a session's terminal view, and makes it first responder when it joins the window, which
/// is when a tab is opened or selected.
private struct TerminalHostView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> FocusingContainer {
        let container = FocusingContainer()
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        return container
    }

    func updateNSView(_ nsView: FocusingContainer, context: Context) {}

    final class FocusingContainer: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, let terminal = subviews.first { window.makeFirstResponder(terminal) }
        }
    }
}
