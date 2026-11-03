import AppKit
import Carbon.HIToolbox

/// Listens, without changing anything, to every key press and mouse click in the session. Needs
/// Input Monitoring. Its owner keeps it alive while it's started: the callback holds it unretained.
/// Never log what it hears.
@MainActor final class KeyEventTap {
    /// The Bool is whether the key goes to xpnd itself.
    private let onKey: (KeyInput, Bool) -> Void
    private let onMouseDown: () -> Void
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    init(onKey: @escaping (KeyInput, Bool) -> Void, onMouseDown: @escaping () -> Void) {
        self.onKey = onKey
        self.onMouseDown = onMouseDown
    }

    /// False when macOS refused the tap, as it does without Input Monitoring.
    func start() -> Bool {
        guard port == nil else { return true }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
        // A C function pointer: it reaches the tap only through `userInfo`.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                let tap = Unmanaged<KeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
                // The tap's run loop source is on the main run loop.
                MainActor.assumeIsolated { tap.received(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
    }

    private func received(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            onKey(.reset, false) // keys were missed while it was off
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouseDown()
        case .keyDown:
            guard event.getIntegerValueField(.eventSourceUserData) != SyntheticEvent.marker else { return }
            // A password field: don't read the key, and don't let earlier keys combine with later ones.
            guard !IsSecureEventInputEnabled() else { return onKey(.reset, false) }
            var chars = [UniChar](repeating: 0, count: 8)
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
            let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
            // The picker is a non-activating panel, so it can be key while the app isn't active.
            let targetsXpnd = event.getIntegerValueField(.eventTargetUnixProcessID) == Int64(getpid())
                || NSApp.isActive || NSApp.keyWindow != nil
            onKey(KeyInput.classify(keyCode: keyCode, characters: String(utf16CodeUnits: chars, count: length), flags: event.flags),
                  targetsXpnd)
        default:
            break
        }
    }
}
