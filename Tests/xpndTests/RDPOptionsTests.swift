import Foundation
import Testing
@testable import xpnd

struct RDPOptionsTests {
    @Test func emptyOptionsResolveToDefaults() {
        let c = RDPOptions().resolved(over: .standard, host: "h", port: 3389, username: "u", domain: "D")
        let d = RDPSettings.standard
        #expect(c == RDPSessionConfig(
            host: "h", port: 3389, username: "u", domain: "D", display: .fit, scaleToFit: d.scaleToFit,
            colorDepth: 32, retina: true, clipboard: true, audio: .local, printers: false, commandAsWindowsKey: true,
            nla: true, timeoutSeconds: 15, autoReconnect: true, reconnectTries: 5, performance: .auto,
            gateway: nil, alternateShell: "", consoleSession: false))
    }

    @Test func setOptionsOverrideDefaults() {
        let gw = RDPOptions.Gateway(host: "gw")
        let c = RDPOptions(display: .fixed(width: 1280, height: 720), audio: .off, gateway: gw)
            .resolved(over: .standard, host: "h", port: 3389, username: nil, domain: nil)
        #expect(c.display == .fixed(width: 1280, height: 720))
        #expect(c.audio == .off)
        #expect(c.gateway == gw)
        #expect(c.gateway?.port == 443)
        #expect(c.colorDepth == 32)
        #expect(c.clipboard)
    }

    @Test func onlySetKeysEncode() throws {
        let o = RDPOptions(audio: .off)
        let data = try JSONEncoder().encode(o)
        #expect(try JSONDecoder().decode(RDPOptions.self, from: data) == o)
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["audio"])
    }

    @Test func rdpConnectionRoundTripsThroughYAML() throws {
        let opts = RDPOptions(display: .fixed(width: 1920, height: 1080), nla: false,
                              gateway: .init(host: "gw", port: 8443), alternateShell: "notepad")
        let c = Connection(name: "win", type: .rdp, host: "win", username: "me", domain: "CORP", rdp: opts)
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: [c])])
        let yaml = ConnectionYAML.encode(lib)
        #expect(yaml.contains("type: rdp"))
        #expect(yaml.contains("1920x1080"))
        #expect(try ConnectionYAML.decode(yaml) == lib)
    }

    @Test func defaultPortIs3389() {
        #expect(ConnectionType.rdp.defaultPort == 3389)
        #expect(Connection(name: "w", type: .rdp, host: "w").effectivePort == 3389)
    }

    @Test func gatewayDecodesWithoutPort() throws {
        let g = try JSONDecoder().decode(RDPOptions.Gateway.self, from: Data(#"{"host":"gw"}"#.utf8))
        #expect(g == RDPOptions.Gateway(host: "gw", port: 443, credential: nil))
        let yaml = """
        folders:
          - name: f
            connections:
              - name: w
                type: rdp
                host: win
                rdp: { gateway: { host: gw } }
        """
        let lib = try ConnectionYAML.decode(yaml)
        #expect(lib.allConnections.first?.rdp?.gateway?.port == 443)
        #expect(try ConnectionYAML.decode(ConnectionYAML.encode(lib)) == lib)
    }
}

extension RDPOptionsTests {
    @Test func cleanupPolicyRoundTrips() throws {
        #expect(RDPSettings.standard.dropFolderCleanup == .never)
        #expect(RDPSettings.standard.dropDrive)
        var s = RDPSettings.standard
        s.dropFolderCleanup = .after7Days
        #expect(try JSONDecoder().decode(RDPSettings.self, from: JSONEncoder().encode(s)) == s)
    }
}
