import SwiftUI

/// The fly-out toolbar at the top-centre of a Windows desktop tab. Its frame is the handle or the row and
/// nothing wider, so every other mouse event and drag reaches the desktop. No button takes the keyboard;
/// a popover holds it only while open.
struct RDPNotch: View {
    let model: RDPNotchModel

    private enum Panel { case display, files, info }

    @State private var panel: Panel?
    @State private var info: RDPConnectionInfo?
    @State private var isHovering = false
    @State private var isDropTarget = false
    @State private var confirmingClear = false
    @State private var settling: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsRow: Bool { model.isExpanded || panel != nil }

    var body: some View {
        VStack(spacing: 4) {
            // One container, so the hover and the drop survive the swap (a Group would give each its own).
            ZStack { if showsRow { row } else { handle } }
                .onHover { isHovering = $0; settle() }
                // The handle too: a drag doesn't hover, and the row only opens once something is over it.
                .background(RDPFileDropTarget(accept: model.dropOnNotch) { isDropTarget = $0; settle() })
            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 360)
                    .allowsHitTesting(false)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsRow)
        .onChange(of: panel) {
            guard panel == nil else { return }
            model.restoreFocus()
            settle()
        }
        .task(id: model.notice) {
            guard let notice = model.notice else { return }
            AccessibilityNotification.Announcement(notice).post()
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { model.notice = nil }
        }
        .onChange(of: showsRow, initial: true) { if showsRow { model.refreshDropCount() } }
        // Here, not on the button: the popover closes first, and a transient popover can't hold a dialog.
        .confirmationDialog("Clear \(EditorRules.count(model.dropCount, "file")) from the drop folder?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { model.clearDropFolder() }
            Button("Cancel", role: .cancel) { model.restoreFocus() }
        } message: {
            Text("Files Windows saved there are deleted too.")
        }
        .onAppear { model.isExpanded = model.isPinned }
        .onDisappear { settling?.cancel() }
    }

    /// One pending change at a time, cancelled on re-entry, so crossing the edge doesn't flicker.
    private func settle() {
        settling?.cancel()
        let inside = isHovering || isDropTarget
        settling = Task {
            try? await Task.sleep(for: .milliseconds(inside ? 150 : 400))
            guard !Task.isCancelled else { return }
            if inside {
                model.isExpanded = true
            } else if !model.isPinned, panel == nil {
                model.isExpanded = false
            }
        }
    }

    private var handle: some View {
        // VoiceOver can't hover, so the handle is a button too.
        Button { model.isExpanded = true; model.restoreFocus() } label: {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(.separator))
                .frame(width: 56, height: 6)
                .padding(.vertical, 3) // a 6 pt target is too thin for the pointer
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Desktop toolbar (⌘⇧N)")
        .accessibilityLabel("Show desktop toolbar")
    }

    private var row: some View {
        HStack(spacing: 2) {
            item("keyboard", "Ctrl+Alt+Del", help: "Ctrl+Alt+Del: send it to Windows, not to this Mac", action: model.ctrlAltDel)
                .disabled(!model.isConnected)
            item("terminal", "Win+R", help: "Win+R: open the Run box", action: model.winR)
                .disabled(!model.isConnected)
            item("arrow.up.left.and.arrow.down.right", "Full screen", help: "Enter or leave full screen", action: model.fullScreen)
            item("display", "Display", help: "Change the desktop size for this session") { model.restoreFocus(); panel = .display }
                .disabled(!model.isConnected)
                .popover(isPresented: shows(.display), arrowEdge: .bottom) { displayPanel }
            item(audioSymbol, "Audio", help: "Audio: \(RDPOptionLabels.label(for: model.audio)). Changing it reconnects.", action: model.cycleAudio)
                .accessibilityValue(RDPOptionLabels.label(for: model.audio))
            item("doc.on.clipboard", "Clipboard sync", help: "\(model.clipboardButtonTitle), for this session", action: model.toggleClipboard)
                .opacity(model.clipboardOn ? 1 : 0.45)
                .accessibilityValue(model.clipboardButtonTitle)
            files
            item("arrow.clockwise", "Reconnect", help: "Reconnect this session", action: model.reconnect)
            item("xmark.circle", "Disconnect", help: "Disconnect and end this session", action: model.disconnect)
            item("info.circle", "Info", help: "Connection details") {
                model.restoreFocus()
                info = model.info
                panel = .info
            }
            .popover(isPresented: shows(.info), arrowEdge: .bottom) {
                if let info { RDPInfoPanel(info: info, displayRefused: model.displayRefused) }
            }
            item(model.isPinned ? "pin.fill" : "pin", model.isPinned ? "Unpin toolbar" : "Pin toolbar",
                 help: model.isPinned ? "Let this toolbar close when the pointer leaves" : "Keep this toolbar open", action: model.togglePin)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Desktop toolbar")
    }

    private var files: some View {
        item("folder.badge.plus", "Files", help: model.dropHelp) {
            model.restoreFocus()
            model.refreshDropCount()
            panel = .files
        }
        .overlay(alignment: .topTrailing) {
            if model.dropCount > 0 {
                Text("\(model.dropCount)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(Color.accentColor, in: Capsule())
                    .allowsHitTesting(false)
            }
        }
        .accessibilityValue(EditorRules.count(model.dropCount, "file"))
        .popover(isPresented: shows(.files), arrowEdge: .bottom) { filesPanel }
    }

    private var audioSymbol: String {
        switch model.audio {
        case .local: "speaker.wave.2"
        case .remote: "hifispeaker"
        case .off: "speaker.slash"
        }
    }

    private func item(_ symbol: String, _ label: String, help: String, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .accessibilityLabel(label)
    }

    private func shows(_ which: Panel) -> Binding<Bool> {
        Binding(get: { panel == which }, set: { if !$0, panel == which { panel = nil } })
    }

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(RDPOptionLabels.presets, id: \.self) { choice in
                Button { model.chooseDisplay(choice) } label: {
                    Label {
                        Text(RDPOptionLabels.label(for: choice))
                    } icon: {
                        Image(systemName: "checkmark").opacity(choice == model.display ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityAddTraits(choice == model.display ? .isSelected : [])
            }
            .disabled(!model.isConnected)
            Divider()
            Button("Set as this connection's default") {
                model.saveDisplayAsDefault()
                panel = nil
            }
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private var filesPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.driveIsOn {
                Text("\(EditorRules.count(model.dropCount, "file")) in the xpnd drive")
                Text("Drop files here")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .background(RDPFileDropTarget(accept: model.dropOnNotch))
                Button("Open in Explorer") {
                    model.openDropFolderInExplorer()
                    panel = nil
                }
                .disabled(!model.isConnected)
                Button("Show drop folder in Finder") {
                    model.revealDropFolder()
                    panel = nil
                }
                Button("Clear drop folder", role: .destructive) {
                    panel = nil
                    confirmingClear = true
                }
                .disabled(model.dropCount == 0)
                note(model.dropHelp)
                note("Files Windows saves here arrive without macOS's quarantine check, so treat them like downloads.")
            } else {
                Text(model.dropHelp).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The Info popover: `info` is what the session reported when it opened; only the clock moves.
private struct RDPInfoPanel: View {
    let info: RDPConnectionInfo
    let displayRefused: Bool

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            fact("Desktop", displayRefused ? "\(info.desktopText) · Fixed by the server" : info.desktopText)
            fact("Codec", info.codecText)
            fact("Latency", info.latencyText)
            GridRow {
                title("Connected for")
                TimelineView(.periodic(from: .now, by: 1)) { Text(info.connectedForText(at: $0.date)).monospacedDigit() }
            }
            if let gateway = info.gatewayHost { fact("Gateway", gateway) }
            Divider().gridCellUnsizedAxes(.horizontal)
            Text("Certificate (last accepted)").font(.headline).gridCellColumns(2)
            fact("Subject", info.subjectText)
            fact("SHA-256", info.fingerprintText)
            if let note = info.certificateNote {
                Text(note).font(.caption).foregroundStyle(.secondary).gridCellColumns(2)
            }
        }
        .textSelection(.enabled)
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }

    private func title(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            title(name)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}
