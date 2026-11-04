import Foundation

/// The words the editor and Settings use for RDP choices.
enum RDPOptionLabels {
    static let presets: [RDPOptions.Display] = [
        .fit, .fixed(width: 1280, height: 720), .fixed(width: 1920, height: 1080), .fixed(width: 2560, height: 1440),
    ]

    static func label(for display: RDPOptions.Display) -> String {
        switch display {
        case .fit: "Resize to fit"
        case .fixed(let w, let h): presets.contains(display) ? "\(w) × \(h)" : "Custom \(w) × \(h)"
        }
    }

    static func label(for audio: RDPOptions.Audio) -> String {
        switch audio {
        case .local: "Play here"
        case .remote: "Leave on remote"
        case .off: "Off"
        }
    }

    static func label(for performance: RDPOptions.Performance) -> String {
        switch performance {
        case .auto: "Automatic"
        case .lan: "LAN"
        case .broadband: "Broadband"
        }
    }

    static func label(for flag: Bool) -> String { flag ? "On" : "Off" }
}
