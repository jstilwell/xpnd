import AppKit
import Carbon.HIToolbox
import os

enum SyntheticEvent {
    /// Set in `.eventSourceUserData` on every event xpnd posts, so its own event tap can skip them.
    static let marker: Int64 = 0x78706E64
}

@MainActor protocol KeystrokeSending {
    func backspace(times: Int) async
    func paste(_ text: String) async
    func press(_ key: KeyName, times: Int) async
    func press(_ combo: KeyCombo) async
    /// Puts back what the clipboard held before the first `paste` since the last restore, unless someone copied since.
    func restoreClipboard() async
}

@MainActor final class CGEventKeystrokeSender: KeystrokeSending {
    /// Tuning values: after ⌘V the clipboard stays as written for at least `pasteFloor`, until `pasteReadMargin` after
    /// the app reads it, and at most `pasteCap` (an app that never reads, such as one with no text field focused).
    static let pasteFloor: Duration = .milliseconds(150)
    static let pasteCap: Duration = .seconds(1)
    static let pasteReadMargin: Duration = .milliseconds(50)

    /// The clipboard before this expansion's first paste, and the change count of xpnd's last write over it.
    private var held: (snapshot: PasteboardSnapshot, written: Int)?

    /// The HID system state, not a private one: Screen Sharing reads modifiers from the system's live
    /// state table, which only events from this source update, so a posted Shift or ⌘ shows there.
    private let source = CGEventSource(stateID: .hidSystemState)

    /// The kind of session holding the keyboard focus in xpnd's main window, if any.
    private let focusedSessionKind: @MainActor () -> TerminalSession.Kind?

    init(focusedSessionKind: @escaping @MainActor () -> TerminalSession.Kind? = { nil }) {
        self.focusedSessionKind = focusedSessionKind
    }

    func backspace(times: Int) async { post(KeyName.delete.keyCode, flags: [], times: times) }

    func press(_ key: KeyName, times: Int) async { post(key.keyCode, flags: [], times: times) }

    func press(_ combo: KeyCombo) async {
        var flags: CGEventFlags = []
        if combo.command { flags.insert(.maskCommand) }
        if combo.option { flags.insert(.maskAlternate) }
        if combo.control { flags.insert(.maskControl) }
        if combo.shift { flags.insert(.maskShift) }
        post(combo.keyCode, flags: flags, times: 1)
    }

    /// Pastes, or types where a paste can't land: apps that forward keys to another machine (Screen
    /// Sharing, VNC, RDP, VMs) paste from that machine's clipboard, and ⌘ doesn't survive the trip.
    func paste(_ text: String) async {
        // In an RDP tab a paste would land on the remote clipboard, so it always types.
        if Self.typesKeystrokes(
            in: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, always: AppSettings.shared.typesKeystrokes,
            remoteDesktopTabFocused: focusedSessionKind() == .remoteDesktop)
        {
            return type(text)
        }
        let pasteboard = NSPasteboard.general
        // Someone copied since the last paste: theirs is what to put back.
        let snapshot = if let held, pasteboard.changeCount == held.written { held.snapshot } else { Self.setAside(pasteboard) }
        let written = await Self.write(text, to: pasteboard, floor: Self.pasteFloor, cap: Self.pasteCap, margin: Self.pasteReadMargin) {
            post(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, times: 1)
        }
        held = (snapshot, written)
    }

    func restoreClipboard() async {
        guard let held else { return }
        self.held = nil
        Self.restore(held.snapshot, ifStill: held.written, on: .general)
    }

    // shortcut: the list is the remote-desktop and VM apps known today; add a bundle id (prefix) when a
    // user reports another, or turn on "always" in General settings meanwhile.
    nonisolated static let remoteDesktopApps = [
        "com.apple.ScreenSharing", "com.apple.RemoteDesktop", "com.microsoft.rdc", "com.realvnc.vncviewer",
        "com.p5sys.jump", "com.edovia.screens", "com.lemonmojo.RoyalTSX", "com.parallels.desktop", "com.vmware.fusion", "com.utmapp.UTM",
    ]

    nonisolated static func typesKeystrokes(in bundleID: String?, always: Bool, remoteDesktopTabFocused: Bool) -> Bool {
        always || remoteDesktopTabFocused || remoteDesktopApps.contains { bundleID?.hasPrefix($0) == true }
    }

    /// Types `text` one character at a time as the key that makes it on the current layout (remote
    /// machines get the key code, not the character); a newline is Return. A character no key makes
    /// goes as a Unicode key event, which local apps take and remote ones show as "a".
    private func type(_ text: String) {
        let keys = KeyMap.current().keys
        for character in text {
            if character == "\n" || character == "\r\n" {
                post(KeyName.enter.keyCode, flags: [], times: 1)
            } else if let key = keys[character] {
                post(key.code, flags: key.flags, times: 1)
                if key.dead { post(CGKeyCode(kVK_Space), flags: [], times: 1) } // a dead key and Space type its character
            } else {
                let units = Array(String(character).utf16)
                for down in [true, false] {
                    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
                    event.post(tap: .cghidEventTap)
                }
            }
        }
    }

    /// Puts `text` on `pasteboard` as a promise, runs `postCommandV`, and returns once the app has read it and `margin`
    /// has passed, no sooner than `floor` and no later than `cap`. Returns the change count after the write.
    static func write(
        _ text: String, to pasteboard: NSPasteboard, floor: Duration, cap: Duration, margin: Duration, postCommandV: () -> Void
    ) async -> Int {
        // This Mac only: Universal Clipboard would otherwise send every expansion to the user's other devices.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let promise = PromisedString(text)
        let item = NSPasteboardItem()
        item.setDataProvider(promise, forTypes: [.string])
        // nspasteboard.org markers so clipboard managers don't record the expansion.
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: .init("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        let written = pasteboard.changeCount
        let start = ContinuousClock.now
        postCommandV()
        while true {
            let now = ContinuousClock.now
            if now - start >= cap { break }
            if now - start >= floor, let read = promise.readAt, now - read >= margin { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        withExtendedLifetime(promise) {}
        return written
    }

    /// Pasteboards whose contents a paste has set aside, so clearing a copied secret waits for them to come back.
    private(set) static var settingAside: Set<NSPasteboard.Name> = []

    /// What `pasteboard` holds now, to put back with `restore` once the pastes are done.
    static func setAside(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        settingAside.insert(pasteboard.name)
        return PasteboardSnapshot.capture(pasteboard)
    }

    /// Puts `snapshot` back, unless someone copied after xpnd's write (`written`): their newer content wins.
    static func restore(_ snapshot: PasteboardSnapshot, ifStill written: Int, on pasteboard: NSPasteboard) {
        settingAside.remove(pasteboard.name)
        guard pasteboard.changeCount == written else { return }
        snapshot.restore(to: pasteboard)
    }

    private static let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
        (.maskCommand, CGKeyCode(kVK_Command)), (.maskAlternate, CGKeyCode(kVK_Option)),
        (.maskControl, CGKeyCode(kVK_Control)), (.maskShift, CGKeyCode(kVK_Shift)),
    ]

    /// Presses the modifier keys around the key: Screen Sharing and VNC forward modifiers to the
    /// remote machine as their own key presses, not as flags on the key, so ⌘V alone arrived as "v".
    /// Each modifier event keeps the flags `CGEvent` presets for its key, which include the device bit
    /// saying it's the *left* Shift or ⌘: VNC has only Shift_L and Shift_R keysyms, and Screen Sharing
    /// picks one by that bit, so a bare `.maskShift` sent nothing to the remote machine.
    private func post(_ keyCode: CGKeyCode, flags: CGEventFlags, times: Int) {
        let modifiers = Self.modifierKeys.filter { flags.contains($0.0) }.map(\.1)
        var held: CGEventFlags = []
        var pressed: [(key: CGKeyCode, bits: CGEventFlags)] = []
        for key in modifiers {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) else { continue }
            pressed.append((key, event.flags))
            held.formUnion(event.flags)
            send(event, flags: held)
        }
        for _ in 0..<max(times, 0) {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
                send(event, flags: held)
            }
        }
        for (key, bits) in pressed.reversed() {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { continue }
            held.subtract(bits)
            send(event, flags: held)
        }
    }

    private func send(_ event: CGEvent, flags: CGEventFlags) {
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.marker)
        event.post(tap: .cghidEventTap)
    }
}

/// The pasted text, handed over when the app asks for it, so xpnd knows when the paste was read.
private final class PromisedString: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let text: String
    private let read = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    init(_ text: String) { self.text = text }

    var readAt: ContinuousClock.Instant? { read.withLock { $0 } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        read.withLock { $0 = $0 ?? .now }
        item.setString(text, forType: type)
    }
}
