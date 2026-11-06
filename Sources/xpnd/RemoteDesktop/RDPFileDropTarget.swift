import AppKit
import SwiftUI
import xpndRDP

/// A file drop on the notch. SwiftUI's `.dropDestination` registers `public.data` and `public.item`, so with
/// Finder's types AppKit picks `XPRDPView` (`public.file-url`) under it, and the drop would paste at top-centre.
/// This registers the desktop's own type from a view above it. Drags only: clicks pass to the buttons.
struct RDPFileDropTarget: NSViewRepresentable {
    /// False when nothing was taken, so the drag reports a failed drop.
    let accept: ([URL]) -> Bool
    var onTargeted: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DropView { DropView() }

    func updateNSView(_ view: DropView, context: Context) {
        view.accept = accept
        view.onTargeted = onTargeted
    }

    final class DropView: NSView {
        var accept: ([URL]) -> Bool = { _ in false }
        var onTargeted: (Bool) -> Void = { _ in }

        init() {
            super.init(frame: .zero)
            registerForDraggedTypes([.fileURL])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard !files(sender).isEmpty else { return [] }
            onTargeted(true)
            return .copy
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) { onTargeted(false) }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            defer { onTargeted(false) }
            return accept(files(sender))
        }

        private func files(_ info: any NSDraggingInfo) -> [URL] {
            XPRDPClipboard.fileURLs(on: info.draggingPasteboard)
        }
    }
}
