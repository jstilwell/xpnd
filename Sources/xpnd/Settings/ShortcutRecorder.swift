import AppKit
import SwiftUI

/// Records a key combination: click, then press it. Esc stops without changing it.
/// Copied from HoverEnhance's, without the preview-only options xpnd doesn't use.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        HStack(spacing: 6) {
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.secondary)
            }
            Button(monitor != nil ? "Press a shortcut…" : shortcut?.label ?? "Record Shortcut") {
                if monitor != nil { stop() } else { start() }
            }
            .accessibilityHint(monitor != nil ? "Press the keys, or Escape to stop" : "Click, then press the keys")
            if let shortcut, monitor == nil {
                Button {
                    self.shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove \(shortcut.label)")
                .accessibilityLabel("Remove the shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        // The window just clicked in. A key typed in any other (a terminal tab, say) isn't for the recorder:
        // swallowed, the tab would seem frozen and its first ⌃⌥ combination would become the shortcut.
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window else {
                MainActor.assumeIsolated { stop() }
                return event
            }
            MainActor.assumeIsolated {
                if event.keyCode == 53 {
                    stop()
                } else if let recorded = Shortcut(event: event) {
                    // The current shortcut is held by this app, so it's the one combination not to try.
                    if recorded == shortcut || GlobalShortcut.isAvailable(recorded) {
                        shortcut = recorded
                        stop()
                    } else {
                        problem = "\(recorded.label) is taken"
                    }
                } else {
                    problem = "Use two of ⌘ ⌥ ⌃ ⇧"
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
