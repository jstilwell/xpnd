import Foundation

/// One FreeRDP setting by its `FreeRDP_<Name>` key and the text FreeRDP parses for that key's type.
struct RDPSetting: Equatable, Sendable {
    let name: String
    let value: String
}

extension RDPSessionConfig {
    /// Everything but the password, in a stable order; `configPath` is xpnd's Application Support/xpnd/freerdp.
    func freerdpSettings(configPath: String, viewPixelSize: (width: Int, height: Int), gatewayUsername: String? = nil) -> [RDPSetting] {
        func s(_ name: String, _ value: String) -> RDPSetting { RDPSetting(name: "FreeRDP_" + name, value: value) }
        func s(_ name: String, _ value: Int) -> RDPSetting { s(name, String(value)) }
        func s(_ name: String, _ value: Bool) -> RDPSetting { s(name, value ? "TRUE" : "FALSE") }

        let width: Int, height: Int, fit: Bool
        switch display {
        case .fit:
            fit = true
            (width, height) = retina ? viewPixelSize : (viewPixelSize.width / 2, viewPixelSize.height / 2)
        case .fixed(let w, let h):
            fit = false
            (width, height) = (w, h)
        }
        let connectionType = switch performance { case .auto: 7; case .lan: 6; case .broadband: 4 }
        let lean = performance == .broadband
        let sameCredentials = gateway?.credential == nil

        var out = [
            s("ConfigPath", configPath),
            s("ServerHostname", host), s("ServerPort", port),
            s("DesktopWidth", width), s("DesktopHeight", height),
            s("DynamicResolutionUpdate", fit), s("SupportDisplayControl", fit),
            s("SmartSizing", !fit && scaleToFit),
            s("ColorDepth", colorDepth),
            s("DesktopScaleFactor", retina ? 200 : 100), s("DeviceScaleFactor", retina ? 180 : 100),
            s("RedirectClipboard", clipboard),
            s("AudioPlayback", audio == .local), s("RemoteConsoleAudio", audio == .remote),
            s("RedirectPrinters", printers),
            s("NlaSecurity", nla),
            s("TcpConnectTimeout", timeoutSeconds * 1000),
            s("AutoReconnectionEnabled", autoReconnect), s("AutoReconnectMaxRetries", reconnectTries),
            s("ConnectionType", connectionType),
            s("DisableWallpaper", lean), s("DisableThemes", lean), s("DisableFullWindowDrag", lean),
            s("DisableMenuAnims", lean), s("AllowFontSmoothing", !lean),
            s("GatewayEnabled", gateway != nil),
            s("ConsoleSession", consoleSession),
            s("SupportGraphicsPipeline", true), s("RemoteFxCodec", true), s("GfxProgressive", true),
            s("GfxH264", false), s("GfxAVC444", false),
        ]
        if let username, !username.isEmpty { out.append(s("Username", username)) }
        if let domain, !domain.isEmpty { out.append(s("Domain", domain)) }
        if !alternateShell.isEmpty { out.append(s("AlternateShell", alternateShell)) }
        if let gateway {
            out += [s("GatewayHostname", gateway.host), s("GatewayPort", gateway.port), s("GatewayUseSameCredentials", sameCredentials)]
            if !sameCredentials, let gatewayUsername { out.append(s("GatewayUsername", gatewayUsername)) }
        }
        return out
    }
}
