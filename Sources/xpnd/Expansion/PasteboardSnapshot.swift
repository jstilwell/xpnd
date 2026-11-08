import AppKit

/// Every item on a pasteboard with every type's bytes, in their original order.
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        PasteboardSnapshot(items: (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        })
    }

    func restore(to pasteboard: NSPasteboard) {
        // A restore isn't new content, so Universal Clipboard needn't send it out again.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let fresh = items.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if !fresh.isEmpty { pasteboard.writeObjects(fresh) }
    }
}
