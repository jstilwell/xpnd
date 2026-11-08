import Foundation
import Security
import Testing
@testable import xpnd

/// Answers with its own name, so a test can see which provider a call reached.
private struct Named: CredentialProvider {
    let name: String
    func status(account: String?) async -> ProviderStatus { .notSignedIn(name) }
    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem] {
        [CredentialItem(id: name, vaultID: "v", vaultName: "v", title: name, category: .password, username: nil)]
    }
    func password(for ref: CredentialRef) async throws(CredentialError) -> String { name }
    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String { name }
}

@Suite struct KeychainProviderTests {
    @Test func routesByAccountAndRefProvider() async throws {
        let router = CredentialRouter(onePassword: Named(name: "op"), keychain: Named(name: "kc"))
        #expect(await router.status(account: "ACC1") == .notSignedIn("op"))
        #expect(await router.status(account: KeychainProvider.id) == .notSignedIn("kc"))
        #expect(try await router.search("", account: KeychainProvider.id).map(\.id) == ["kc"])
        let op = CredentialRef(account: "ACC1", vault: "v", item: "i", title: "t", category: .login)
        var kc = op
        kc.provider = KeychainProvider.id
        #expect(try await router.password(for: op) == "op")
        #expect(try await router.password(for: kc) == "kc")
    }

    /// Uses the real login keychain under a throwaway service, removed afterwards.
    @Test func addSearchAndReadBack() async throws {
        let keychain = KeychainProvider(service: "com.jessestilwell.xpnd.tests.\(UUID().uuidString)")
        // The login keychain deletes one match per call.
        defer { while SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: keychain.service] as CFDictionary) == errSecSuccess {} }
        #expect(try await keychain.search("", account: KeychainProvider.id).isEmpty)

        let item = try keychain.add(title: "Web Box", username: "root", password: "s3cret")
        _ = try keychain.add(title: "Wifi", username: "", password: "hunter2")
        let ref = item.ref(account: KeychainProvider.id)
        #expect(ref.provider == KeychainProvider.id && ref.category == .login && ref.username == "root")
        #expect(CredentialRef.isSafe(ref.item) && CredentialRef.isSafe(ref.vault))

        let all = try await keychain.search("", account: KeychainProvider.id)
        #expect(all.map(\.title) == ["Web Box", "Wifi"])
        #expect(all.last?.category == .password)
        #expect(try await keychain.search("ROOT", account: KeychainProvider.id).map(\.title) == ["Web Box"])
        #expect(try await keychain.password(for: ref) == "s3cret")

        var gone = ref
        gone.item = UUID().uuidString
        await #expect(throws: CredentialError.failed("“Web Box” wasn't found in the keychain.")) {
            try await keychain.password(for: gone)
        }
    }
}
