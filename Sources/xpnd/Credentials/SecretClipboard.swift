import AppKit

/// Copies a secret so clipboard managers skip it, then clears it unless the user has copied something newer.
@MainActor enum SecretClipboard {
    static let clearAfter: Duration = .seconds(30)

    @discardableResult
    static func copy(_ secret: String, to pasteboard: NSPasteboard = .general, clearAfter: Duration = clearAfter) -> Task<Void, Never> {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item])
        let written = pasteboard.changeCount
        return Task { @MainActor in
            try? await Task.sleep(for: clearAfter)
            // A newer copy (including a later secret) bumped changeCount, so it keeps its own clock.
            if pasteboard.changeCount == written { pasteboard.clearContents() }
        }
    }
}
