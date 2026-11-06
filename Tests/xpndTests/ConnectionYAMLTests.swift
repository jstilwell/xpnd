import Foundation
import Testing
@testable import xpnd

@Suite struct ConnectionYAMLTests {
    static let prodID = "7f1c0000-0000-4000-8000-000000000001"
    static let awsID = "3a9e0000-0000-4000-8000-000000000002"
    static let bastionID = "91bd0000-0000-4000-8000-000000000003"
    static let devID = "0c440000-0000-4000-8000-000000000004"

    @Test func sudoUsesLoginRoundTrips() throws {
        var library = ConnectionLibrary(folders: [])
        #expect(!ConnectionYAML.encode(library).contains("sudoUsesLogin"))
        #expect(try ConnectionYAML.decode("version: 1\n").sudoUsesLogin)
        library.sudoUsesLogin = false
        let yaml = ConnectionYAML.encode(library)
        #expect(yaml.contains("sudoUsesLogin: false"))
        #expect(try ConnectionYAML.decode(yaml).sudoUsesLogin == false)
    }

    static let spec = """
    version: 1
    credential:
      provider: 1password
      account: acct1
      vault: vault1
      item: item1
      title: "Default SSH"
      category: ssh_key
      username: ubuntu
    sudoCredential: { provider: 1password, account: acct1, vault: vault1, item: item2, title: "sudo", category: password }
    folders:
      - id: \(prodID)
        name: prod
        credential: { provider: 1password, account: acct1, vault: vault1, item: item3, title: "prod-ssh", category: login }
        connections:
          - id: \(awsID)
            name: aws-external-web-services
            type: ssh
            host: 54.242.245.93
            port: 22
            activation: ";aws"
            advanced:
              jumpHost: { connection: \(bastionID) }
              sshOptions: "-o ServerAliveInterval=30"
              autoSudo: true
        folders: []
      - id: \(devID)
        name: dev
        connections: []
        folders: []
    """

    static func cred(_ item: String, username: String? = nil) -> CredentialRef {
        CredentialRef(account: "a", vault: "v", item: item, title: item, category: .login, username: username)
    }

    @Test func decodesSpecExample() throws {
        let lib = try ConnectionYAML.decode(Self.spec)
        #expect(lib.credential?.category == .sshKey)
        #expect(lib.credential?.username == "ubuntu")
        #expect(lib.sudoCredential?.hasPassword == true)
        #expect(lib.folders.map(\.name) == ["prod", "dev"])
        let prod = lib.folders[0]
        #expect(prod.id == UUID(uuidString: Self.prodID))
        #expect(prod.activation == nil)
        #expect(prod.credential?.title == "prod-ssh")
        let aws = prod.connections[0]
        #expect(aws.port == 22)
        #expect(aws.effectivePort == 22)
        #expect(aws.activation == ";aws")
        #expect(aws.jumpHost == .connection(UUID(uuidString: Self.bastionID)!))
        #expect(aws.sshOptions == "-o ServerAliveInterval=30")
        #expect(aws.autoSudo)
        #expect(lib.folders[1].connections.isEmpty)
    }

    @Test func roundTripsWithIDs() throws {
        let jumpTarget = Connection(name: "bastion", host: "b.example.com", username: "ec2-user")
        let viaID = Connection(name: "a", host: "h1", port: 2222, jumpHost: .connection(jumpTarget.id),
                               sshOptions: "-o A=\"b c\"", autoSudo: true)
        let viaText = Connection(name: "v", type: .vnc, host: "h2", activation: ";v",
                                 credential: Self.cred("c1", username: "root"), sudoCredential: Self.cred("c2"),
                                 jumpHost: .text("ec2-user@bastion:22"), color: .green)
        let inner = ConnectionFolder(name: "inner", activation: "", connections: [viaText], color: .blue)
        let outer = ConnectionFolder(name: "outer", credential: Self.cred("c3"),
                                     connections: [jumpTarget, viaID], folders: [inner])
        let lib = ConnectionLibrary(credential: Self.cred("g", username: "me"), sudoCredential: Self.cred("gs"),
                                    folders: [outer])
        #expect(try ConnectionYAML.decode(ConnectionYAML.encode(lib)) == lib)
    }

    @Test func defaultsOmitted() {
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "f", connections: [Connection(name: "c", host: "h")])])
        let yaml = ConnectionYAML.encode(lib)
        #expect(!yaml.contains("port"))
        #expect(!yaml.contains("advanced"))
        #expect(!yaml.contains("activation"))
        #expect(!yaml.contains("color"))
    }

    @Test func colorsAreNamesInYAML() throws {
        let lib = ConnectionLibrary(folders: [ConnectionFolder(name: "lan", connections: [Connection(name: "c", host: "h")], color: .orange)])
        let yaml = ConnectionYAML.encode(lib)
        #expect(yaml.contains("color: orange"))
        #expect(try ConnectionYAML.decode(yaml) == lib)
        #expect(throws: ConnectionYAMLError.self) { try ConnectionYAML.decode(yaml.replacingOccurrences(of: "orange", with: "teal")) }
    }

    @Test func emptyActivationIsNone() throws {
        let lib = try ConnectionYAML.decode("folders:\n  - name: x\n    activation: \"\"\n  - name: y\n")
        #expect(lib.folders[0].activation == "")
        #expect(lib.folders[1].activation == nil)
    }

    @Test func malformedAndVersion() {
        #expect(throws: ConnectionYAMLError.self) { try ConnectionYAML.decode("folders: [") }
        do { _ = try ConnectionYAML.decode("folders: ["); Issue.record("no throw") }
        catch { if case .malformed = error {} else { Issue.record("wrong error \(error)") } }
        #expect(throws: ConnectionYAMLError.unsupportedVersion(2)) { try ConnectionYAML.decode("version: 2\n") }
    }

    @Test func duplicateIDsThrow() {
        let id = "7f1c0000-0000-4000-8000-000000000009"
        let yaml = """
        folders:
          - id: \(id)
            name: a
            connections:
              - { id: \(id), name: c, host: h }
        """
        #expect(throws: ConnectionYAMLError.duplicateIDs([id.uppercased()])) { try ConnectionYAML.decode(yaml) }
    }

    @Test func starterHasDevAndProd() {
        let s = ConnectionLibrary.starter()
        #expect(s.folders.map(\.name) == ["dev", "prod"])
        #expect(s.folders.allSatisfy { $0.activation == nil && $0.connections.isEmpty })
        #expect(s.folders[0].id != s.folders[1].id)
    }
}
