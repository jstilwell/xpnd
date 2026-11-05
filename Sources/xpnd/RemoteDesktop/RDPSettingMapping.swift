import Foundation

/// One FreeRDP setting by its `FreeRDP_<Name>` key and the text FreeRDP parses for that key's type.
struct RDPSetting: Equatable, Sendable {
    let name: String
    let value: String
}

/// FreeRDP splits `DOMAIN\user` only in its command-line and .rdp parsers (`freerdp_parse_username`);
/// its core hands the username to NTLM as is, so xpnd splits it. `user@domain` stays whole, as there.
enum RDPLogin {
    /// A domain carried by the username wins: `CORP\me` splits at the first `\`, and `me@corp.local`
    /// is sent whole (FreeRDP resolves the UPN), so the Domain field only matters for a plain name.
    static func split(username: String, domain: String?) -> (username: String, domain: String?) {
        let domain = domain?.isEmpty == false ? domain : nil
        if username.contains("@") { return (username, nil) }
        guard let slash = username.firstIndex(of: "\\") else { return (username, domain) }
        let prefix = String(username[..<slash])
        return (String(username[username.index(after: slash)...]), prefix.isEmpty ? domain : prefix)
    }

    /// The domain a username carries, for the editor to show instead of a Domain field: "" for a UPN,
    /// nil for a plain name.
    static func carriedDomain(in username: String) -> String? {
        if username.contains("@") { return "" }
        guard let slash = username.firstIndex(of: "\\"), slash != username.startIndex else { return nil }
        return String(username[..<slash])
    }
}

extension RDPSessionConfig {
    /// Everything but the password, in a stable order; `configPath` is xpnd's Application Support/xpnd/freerdp.
    func freerdpSettings(configPath: String, viewPixelSize: (width: Int, height: Int)) -> [RDPSetting] {
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
            s("DynamicResolutionUpdate", fit), s("SupportDisplayControl", true),
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
        let login = RDPLogin.split(username: username ?? "", domain: domain)
        if !login.username.isEmpty { out.append(s("Username", login.username)) }
        if let domain = login.domain { out.append(s("Domain", domain)) }
        if driveDevice() != nil { out.append(s("DeviceRedirection", true)) }
        if !alternateShell.isEmpty { out.append(s("AlternateShell", alternateShell)) }
        if let gateway {
            out += [s("GatewayHostname", gateway.host), s("GatewayPort", gateway.port), s("GatewayUseSameCredentials", sameCredentials)]
            // FreeRDP copies the login to the gateway only in its command-line post-processing, which xpnd doesn't run.
            let gatewayLogin = gateway.credential.map { RDPLogin.split(username: $0.username ?? "", domain: nil) } ?? login
            if !gatewayLogin.username.isEmpty { out.append(s("GatewayUsername", gatewayLogin.username)) }
            if let domain = gatewayLogin.domain { out.append(s("GatewayDomain", domain)) }
        }
        return out
    }
}
