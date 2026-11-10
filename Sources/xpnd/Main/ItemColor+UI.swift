import SwiftUI

extension ItemColor {
    var ui: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

    var label: String { rawValue.capitalized }
}

/// A colour picker for a folder or connection: the palette, or nothing of its own (the nil row
/// says what it inherits, if anything).
struct ColorChoice: View {
    let own: ItemColor?
    /// What the item gets with no colour of its own: the nearest ancestor folder's.
    let inherited: ResolvedColor?
    let set: @MainActor (ItemColor?) -> Void

    var body: some View {
        Picker("Color", selection: Binding(get: { own }, set: set)) {
            if let inherited {
                swatch(inherited.color, "\(inherited.color.label) from “\(inherited.inheritedFrom ?? "")”").tag(nil as ItemColor?)
            } else {
                Text("None").tag(nil as ItemColor?)
            }
            Divider()
            ForEach(ItemColor.allCases, id: \.self) { color in
                swatch(color, color.label).tag(Optional(color))
            }
        }
    }

    private func swatch(_ color: ItemColor, _ text: String) -> some View {
        Label { Text(text) } icon: { Image(nsImage: color.swatch) }
    }
}

extension ItemColor {
    /// A filled circle with the colour drawn in. A menu-style Picker turns its rows into NSMenuItems,
    /// which paint a template image (such as a styled SF Symbol) in the menu's own tint; a
    /// non-template bitmap keeps its colour.
    @MainActor var swatch: NSImage { Self.swatches[self]! }

    /// Drawn once: a colour menu asks for all of them on every pass.
    @MainActor private static let swatches = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.drawSwatch()) })

    private func drawSwatch() -> NSImage {
        // A fixed NSColor, not NSColor(ui): the menu rasterizes the image without an appearance to
        // resolve a dynamic colour against, and the dot came out white.
        let fill: NSColor = switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
