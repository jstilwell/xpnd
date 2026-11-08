import Foundation
import Security

/// Passwords xpnd keeps in the login keychain, one generic-password item each under `service`.
/// Items xpnd creates trust xpnd's signature, so reading them back doesn't prompt. No SSH keys:
/// those stay in ~/.ssh or ssh-agent.
struct KeychainProvider: CredentialProvider {
    /// The account id and `CredentialRef.provider` of Keychain refs.
    static let id = "keychain"
    var service = "com.jessestilwell.xpnd.credential"

    func status(account: String?) async -> ProviderStatus {
        .ready([ProviderAccount(id: Self.id, email: "Login keychain", url: "")])
    }

    /// Reads attributes only, never the secrets, so listing never prompts.
    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw Self.error(status) }
        let q = query.lowercased()
        return rows.compactMap(Self.item)
            .filter { q.isEmpty || [$0.title, $0.username ?? ""].contains { $0.lowercased().contains(q) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func password(for ref: CredentialRef) async throws(CredentialError) -> String {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: ref.item,
            kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { throw .failed("“\(ref.title)” wasn't found in the keychain.") }
        guard status == errSecSuccess else { throw Self.error(status) }
        guard let data = result as? Data, let password = String(data: data, encoding: .utf8), !password.isEmpty
        else { throw .noPassword(ref.title) }
        return password
    }

    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String {
        throw .failed("The macOS Keychain doesn't hold SSH keys. Use ~/.ssh or 1Password for them.")
    }

    /// Saves a new password and returns it as a pickable item.
    func add(title: String, username: String?, password: String) throws(CredentialError) -> CredentialItem {
        let id = UUID().uuidString
        let username = username?.isEmpty == true ? nil : username
        var attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id,
            kSecAttrLabel: title, kSecValueData: Data(password.utf8),
        ]
        if let username { attributes[kSecAttrComment] = username }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status) }
        return Self.item(id: id, title: title, username: username)
    }

    // MARK: helpers

    private static func item(_ row: [String: Any]) -> CredentialItem? {
        guard let id = row[kSecAttrAccount as String] as? String else { return nil }
        return item(id: id, title: row[kSecAttrLabel as String] as? String ?? id,
                    username: (row[kSecAttrComment as String] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    private static func item(id: String, title: String, username: String?) -> CredentialItem {
        CredentialItem(id: id, vaultID: "login", vaultName: "Keychain", title: title,
                       category: username == nil ? .password : .login, username: username, provider: Self.id)
    }

    private static func error(_ status: OSStatus) -> CredentialError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            .failed("The keychain is locked, or access to it was denied.")
        default:
            .failed(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status).")
        }
    }
}
