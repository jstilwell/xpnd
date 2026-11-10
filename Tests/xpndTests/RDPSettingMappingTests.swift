import Foundation
import Testing
@testable import xpnd

@Suite struct RDPSettingMappingTests {
    private func config(_ edit: (inout RDPSessionConfig) -> Void = { _ in }) -> RDPSessionConfig {
        var c = RDPOptions().resolved(over: .standard, host: "pc.example.com", port: 3389, username: "bob", domain: "CORP")
        edit(&c)
        return c
    }

    private func value(_ c: RDPSessionConfig, _ name: String, size: (width: Int, height: Int) = (2880, 1800)) -> String? {
        c.freerdpSettings(configPath: "/tmp/freerdp", viewPixelSize: size).first { $0.name == name }?.value
    }

    @Test func fitUsesViewSizeAndDynamicResolution() {
        let c = config()
        #expect(value(c, "FreeRDP_DesktopWidth") == "2880")
        #expect(value(c, "FreeRDP_DesktopHeight") == "1800")
        #expect(value(c, "FreeRDP_DynamicResolutionUpdate") == "TRUE")
        #expect(value(c, "FreeRDP_SupportDisplayControl") == "TRUE")
        #expect(value(c, "FreeRDP_DesktopScaleFactor") == "200")
        #expect(value(c, "FreeRDP_DeviceScaleFactor") == "180")
    }

    @Test func dropDriveDefaultsOnAndEmitsRedirection() {
        let c = config { $0.dropFolder = "/x" }
        #expect(value(c, "FreeRDP_DeviceRedirection") == "TRUE")
        #expect(c.driveDevice()?.name == "xpnd")
        #expect(c.driveDevice()?.path == "/x")
    }

    @Test func dropDriveOffEmitsNoDevice() {
        let c = config { $0.dropFolder = "/x"; $0.dropDrive = false }
        #expect(value(c, "FreeRDP_DeviceRedirection") == nil)
        #expect(c.driveDevice() == nil)
    }

    @Test func displayControlIsAlwaysNegotiated() {
        let c = config { $0.display = .fixed(width: 1280, height: 720) }
        #expect(value(c, "FreeRDP_SupportDisplayControl") == "TRUE")
        #expect(value(c, "FreeRDP_DynamicResolutionUpdate") == "FALSE")
    }

    @Test func retinaOffHalvesTheViewSize() {
        let c = config { $0.retina = false }
        #expect(value(c, "FreeRDP_DesktopWidth") == "1440")
        #expect(value(c, "FreeRDP_DesktopHeight") == "900")
        #expect(value(c, "FreeRDP_DesktopScaleFactor") == "100")
        #expect(value(c, "FreeRDP_DeviceScaleFactor") == "100")
    }

    @Test func fixedUsesItsSizeAndIgnoresScaleToFit() {
        // XPRDPView letterboxes a fixed size whatever scaleToFit says (1:1 isn't implemented).
        for scale in [true, false] {
            let c = config { $0.display = .fixed(width: 1280, height: 720); $0.scaleToFit = scale }
            #expect(value(c, "FreeRDP_DesktopWidth") == "1280")
            #expect(value(c, "FreeRDP_DesktopHeight") == "720")
            #expect(value(c, "FreeRDP_DynamicResolutionUpdate") == "FALSE")
            #expect(value(c, "FreeRDP_SmartSizing") == nil)
        }
    }

    @Test func audioModes() {
        for (mode, play, remote) in [(RDPOptions.Audio.local, "TRUE", "FALSE"), (.remote, "FALSE", "TRUE"), (.off, "FALSE", "FALSE")] {
            let c = config { $0.audio = mode }
            #expect(value(c, "FreeRDP_AudioPlayback") == play)
            #expect(value(c, "FreeRDP_RemoteConsoleAudio") == remote)
        }
    }

    @Test func aBackslashLoginIsSplitIntoDomainAndUser() {
        let c = config { $0.username = #"CORP\me"#; $0.domain = nil }
        #expect(value(c, "FreeRDP_Username") == "me")
        #expect(value(c, "FreeRDP_Domain") == "CORP")
    }

    @Test func theBackslashWinsOverTheDomainField() {
        let c = config { $0.username = #"OTHER\me"#; $0.domain = "CORP" }
        #expect(value(c, "FreeRDP_Username") == "me")
        #expect(value(c, "FreeRDP_Domain") == "OTHER")
    }

    @Test func aUPNIgnoresTheDomainField() {
        let c = config { $0.username = "me@corp.local"; $0.domain = "CORP" }
        #expect(value(c, "FreeRDP_Username") == "me@corp.local")
        #expect(value(c, "FreeRDP_Domain") == nil)
    }

    @Test func carriedDomainDrivesTheEditor() {
        #expect(RDPLogin.carriedDomain(in: #"CORP\me"#) == "CORP")
        #expect(RDPLogin.carriedDomain(in: "me@corp.local") == "")
        #expect(RDPLogin.carriedDomain(in: "me") == nil)
        #expect(RDPLogin.carriedDomain(in: #"\me"#) == nil)
    }

    @Test func aUPNLoginStaysWhole() {
        let c = config { $0.username = "me@corp.local"; $0.domain = nil }
        #expect(value(c, "FreeRDP_Username") == "me@corp.local")
        #expect(value(c, "FreeRDP_Domain") == nil)
    }

    @Test func gatewayWithTheSameCredentialsSendsTheLogin() {
        #expect(value(config(), "FreeRDP_GatewayEnabled") == "FALSE")
        #expect(value(config(), "FreeRDP_GatewayUsername") == nil)
        let c = config { $0.username = #"CORP\me"#; $0.domain = nil; $0.gateway = .init(host: "gw.example.com", port: 8443, credential: nil) }
        #expect(value(c, "FreeRDP_GatewayEnabled") == "TRUE")
        #expect(value(c, "FreeRDP_GatewayHostname") == "gw.example.com")
        #expect(value(c, "FreeRDP_GatewayPort") == "8443")
        #expect(value(c, "FreeRDP_GatewayUseSameCredentials") == "TRUE")
        #expect(value(c, "FreeRDP_GatewayUsername") == "me")
        #expect(value(c, "FreeRDP_GatewayDomain") == "CORP")
    }

    @Test func gatewayWithOwnCredentialSendsItsLoginSplit() {
        let ref = CredentialRef(account: "a", vault: "v", item: "i", title: "t", category: .login, username: #"GW\svc"#)
        let c = config { $0.gateway = .init(host: "gw", port: 443, credential: ref) }
        #expect(value(c, "FreeRDP_GatewayUseSameCredentials") == "FALSE")
        #expect(value(c, "FreeRDP_GatewayUsername") == "svc")
        #expect(value(c, "FreeRDP_GatewayDomain") == "GW")
        #expect(value(c, "FreeRDP_Username") == "bob")
        #expect(value(c, "FreeRDP_Domain") == "CORP")
        let noUser = config { $0.gateway = .init(host: "gw", port: 443, credential: CredentialRef(account: "a", vault: "v", item: "i", title: "t", category: .login)) }
        #expect(value(noUser, "FreeRDP_GatewayUsername") == nil)
        #expect(value(noUser, "FreeRDP_GatewayDomain") == nil)
    }

    @Test func performancePresets() {
        #expect(value(config { $0.performance = .lan }, "FreeRDP_ConnectionType") == "6")
        #expect(value(config { $0.performance = .lan }, "FreeRDP_DisableWallpaper") == "FALSE")
        #expect(value(config { $0.performance = .broadband }, "FreeRDP_ConnectionType") == "4")
        #expect(value(config { $0.performance = .broadband }, "FreeRDP_DisableWallpaper") == "TRUE")
        #expect(value(config { $0.performance = .auto }, "FreeRDP_ConnectionType") == "7")
    }

    @Test func securityAndMisc() {
        let c = config { $0.alternateShell = "cmd.exe"; $0.consoleSession = true }
        #expect(value(c, "FreeRDP_NlaSecurity") == "TRUE")
        // FreeRDP leaves TLS-only and legacy RDP security on by default: NLA on must mean NLA only, and the
        // legacy mode (no certificate check at all) is never offered.
        #expect(value(c, "FreeRDP_TlsSecurity") == "FALSE")
        #expect(value(c, "FreeRDP_RdpSecurity") == "FALSE")
        let noNLA = config { $0.nla = false }
        #expect(value(noNLA, "FreeRDP_NlaSecurity") == "FALSE")
        #expect(value(noNLA, "FreeRDP_TlsSecurity") == "TRUE")
        #expect(value(noNLA, "FreeRDP_RdpSecurity") == "FALSE")
        #expect(value(c, "FreeRDP_TcpConnectTimeout") == "15000")
        #expect(value(c, "FreeRDP_AutoReconnectMaxRetries") == "5")
        #expect(value(c, "FreeRDP_ConsoleSession") == "TRUE")
        #expect(value(c, "FreeRDP_AlternateShell") == "cmd.exe")
        #expect(value(c, "FreeRDP_ConfigPath") == "/tmp/freerdp")
        #expect(value(c, "FreeRDP_GfxH264") == "FALSE")
        #expect(value(c, "FreeRDP_ServerHostname") == "pc.example.com")
        #expect(value(c, "FreeRDP_Username") == "bob")
    }

    @Test func neverContainsAPassword() {
        let ref = CredentialRef(account: "a", vault: "v", item: "i", title: "t", category: .login, username: "svc")
        for gateway in [nil, RDPOptions.Gateway(host: "gw"), RDPOptions.Gateway(host: "gw", credential: ref)] {
            let names = config { $0.gateway = gateway }.freerdpSettings(configPath: "/x", viewPixelSize: (100, 100)).map(\.name)
            #expect(!names.contains { $0.contains("Password") })
        }
    }
}
