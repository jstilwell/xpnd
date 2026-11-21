import AppKit

/// How an expansion started: `#{selection}` reads the selection only from the picker, since typing a keyword has
/// already replaced any selection (and editors copy the whole line on ⌘C with nothing selected).
enum ExpansionTrigger: Sendable {
    case typed, picker
}

@MainActor enum SelectionCopy {
    /// Presses ⌘C (`press`), waits up to `timeout` for the pasteboard to change, reads its string, and puts the clipboard
    /// back as it was. nil when nothing was copied in time.
    static func read(on pasteboard: NSPasteboard, timeout: Duration = .milliseconds(300), press: @MainActor () async -> Void) async -> String? {
        let start = pasteboard.changeCount
        let snapshot = CGEventKeystrokeSender.setAside(pasteboard)
        await press()
        let deadline = ContinuousClock.now + timeout
        while pasteboard.changeCount == start, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // shortcut: an app that handles ⌘C after the timeout copies over the clipboard with nothing to put it back (and its
        // ⌘V may paste the selection); keep the snapshot until the expansion ends if users of slow apps report it.
        guard pasteboard.changeCount != start else {
            CGEventKeystrokeSender.endSettingAside(pasteboard) // nothing to put back
            return nil
        }
        let text = pasteboard.string(forType: .string)
        CGEventKeystrokeSender.restore(snapshot, ifStill: pasteboard.changeCount, on: pasteboard)
        return text
    }
}
