import AppKit

/// Copies a secret so clipboard managers skip it, then clears it unless the user has copied something newer.
/// Each copy carries its own pasteboard type. `changeCount` can't tell: a paste's restore bumps it
/// while putting the secret back, and restoring keeps every type.
@MainActor enum SecretClipboard {
    static let clearAfter: Duration = .seconds(30)
    /// Tuning value: outlasts a paste, which has the secret set aside until its settle ends.
    private static let recheckAfter = CGEventKeystrokeSender.pasteSettle * 2

    /// The last copy's tag, so quitting can clear a secret still on the clipboard.
    private static var lastTag: NSPasteboard.PasteboardType?

    @discardableResult
    static func copy(_ secret: String, to pasteboard: NSPasteboard = .general, clearAfter: Duration = clearAfter) -> Task<Void, Never> {
        let tag = NSPasteboard.PasteboardType("com.jessestilwell.xpnd.secret.\(UUID().uuidString)")
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: tag)
        pasteboard.writeObjects([item])
        lastTag = tag
        return Task { @MainActor in
            for wait in [clearAfter, recheckAfter] {
                try? await Task.sleep(for: wait)
                // A newer copy (including a later secret) lacks the tag, so it keeps its own clock.
                guard pasteboard.types?.contains(tag) == true else { continue }
                pasteboard.clearContents()
                return
            }
        }
    }

    /// Clears the clipboard if it still holds the last secret xpnd copied, as when quitting.
    static func clearIfOwned(_ pasteboard: NSPasteboard = .general) {
        guard let lastTag, pasteboard.types?.contains(lastTag) == true else { return }
        pasteboard.clearContents()
    }
}
