import Testing
@testable import xpnd

struct CredentialItemTests {
    private let web = CredentialItem(id: "1", vaultID: "v", vaultName: "Work", title: "Web Server", category: .login, username: "deploy")
    private let local = CredentialItem(id: "2", vaultID: "login", vaultName: "Keychain", title: "NAS", category: .password,
                                       username: nil, provider: KeychainProvider.id)

    /// The picker lists an account once and filters as the search field changes.
    @Test func aSearchFindsTitleVaultOrUsernameWhateverTheCase() {
        #expect(web.matches("web"))
        #expect(web.matches("WORK"))
        #expect(web.matches("Deploy"))
        #expect(web.matches(""))
        #expect(!web.matches("nas"))
    }

    /// Every Keychain item's vault is "Keychain", so matching it would match them all.
    @Test func aKeychainItemIsNotFoundByItsVault() {
        #expect(local.matches("nas"))
        #expect(!local.matches("keychain"))
    }
}
