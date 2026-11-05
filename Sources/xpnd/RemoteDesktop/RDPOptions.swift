import Foundation

/// Per-connection RDP overrides. Every field is optional and only set keys encode; nil inherits `RDPSettings`.
struct RDPOptions: Codable, Hashable, Sendable {
    enum Display: Hashable, Sendable { case fit, fixed(width: Int, height: Int) }
    enum Audio: String, Codable, Sendable { case local, remote, off }
    enum Performance: String, Codable, Sendable { case auto, lan, broadband }
    struct Gateway: Codable, Hashable, Sendable {
        var host: String
        var port: Int = 443
        /// nil uses the connection's own credential.
        var credential: CredentialRef?
    }

    var display: Display?
    var scaleToFit: Bool?
    var colorDepth: Int?
    var retina: Bool?
    var clipboard: Bool?
    var audio: Audio?
    var printers: Bool?
    var commandAsWindowsKey: Bool?
    var nla: Bool?
    var timeoutSeconds: Int?
    var autoReconnect: Bool?
    var reconnectTries: Int?
    var performance: Performance?
    var gateway: Gateway?
    var alternateShell: String?
    var consoleSession: Bool?
}

/// In an extension to keep the memberwise init; `port` and `credential` may be omitted in hand-written YAML.
extension RDPOptions.Gateway {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 443
        credential = try c.decodeIfPresent(CredentialRef.self, forKey: .credential)
    }
}

/// Reads and writes as `fit` or `1280x720`, which stays hand-editable in YAML.
extension RDPOptions.Display: Codable {
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: "x").compactMap { Int($0) }
        if text == "fit" { self = .fit } else if parts.count == 2, parts.allSatisfy({ $0 > 0 }) {
            self = .fixed(width: parts[0], height: parts[1])
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected \"fit\" or \"<width>x<height>\""))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .fit: try c.encode("fit")
        case .fixed(let w, let h): try c.encode("\(w)x\(h)")
        }
    }
}

/// App-wide RDP defaults, which a connection's `RDPOptions` override.
struct RDPSettings: Codable, Hashable, Sendable {
    var display = RDPOptions.Display.fit
    var scaleToFit = true
    var colorDepth = 32
    var retina = true
    var clipboard = true
    var audio = RDPOptions.Audio.local
    var printers = false
    var commandAsWindowsKey = true
    var nla = true
    var timeoutSeconds = 15
    var autoReconnect = true
    var reconnectTries = 5
    var performance = RDPOptions.Performance.auto
    var alternateShell = ""
    var consoleSession = false

    static let standard = RDPSettings()
}

/// Everything one RDP session needs, with defaults applied.
struct RDPSessionConfig: Equatable, Sendable {
    var host: String
    var port: Int
    var username: String?
    var domain: String?
    var display: RDPOptions.Display
    var scaleToFit: Bool
    var colorDepth: Int
    var retina: Bool
    var clipboard: Bool
    var audio: RDPOptions.Audio
    var printers: Bool
    var commandAsWindowsKey: Bool
    var nla: Bool
    var timeoutSeconds: Int
    var autoReconnect: Bool
    var reconnectTries: Int
    var performance: RDPOptions.Performance
    var gateway: RDPOptions.Gateway?
    var alternateShell: String
    var consoleSession: Bool
}

extension RDPOptions {
    func resolved(over d: RDPSettings, host: String, port: Int, username: String?, domain: String?) -> RDPSessionConfig {
        RDPSessionConfig(
            host: host, port: port, username: username, domain: domain,
            display: display ?? d.display, scaleToFit: scaleToFit ?? d.scaleToFit,
            colorDepth: colorDepth ?? d.colorDepth, retina: retina ?? d.retina,
            clipboard: clipboard ?? d.clipboard, audio: audio ?? d.audio, printers: printers ?? d.printers,
            commandAsWindowsKey: commandAsWindowsKey ?? d.commandAsWindowsKey, nla: nla ?? d.nla,
            timeoutSeconds: timeoutSeconds ?? d.timeoutSeconds, autoReconnect: autoReconnect ?? d.autoReconnect,
            reconnectTries: reconnectTries ?? d.reconnectTries, performance: performance ?? d.performance,
            gateway: gateway, alternateShell: alternateShell ?? d.alternateShell,
            consoleSession: consoleSession ?? d.consoleSession)
    }
}
