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
    let set: (ItemColor?) -> Void

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
        Label { Text(text) } icon: { Image(systemName: "circle.fill").foregroundStyle(color.ui) }
    }
}
