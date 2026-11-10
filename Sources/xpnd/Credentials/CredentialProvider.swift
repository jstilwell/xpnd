import Foundation

struct ProviderAccount: Hashable, Sendable {
    let id: String
    let email: String
    let url: String
}

enum ProviderStatus: Equatable, Sendable {
    case notInstalled, notSignedIn(String)
    /// More than one account and none chosen (or the chosen one is gone): the caller must ask, never guess.
    case chooseAccount([ProviderAccount])
    case ready([ProviderAccount])
}

struct CredentialItem: Hashable, Sendable {
    let id: String
    let vaultID: String
    let vaultName: String
    let title: String
    let category: CredentialCategory
    let username: String?
    var provider = "1password"

    /// Whether a search for `query` finds this item: in its title, username or (1Password) vault, whatever
    /// the case. Every Keychain item's vault is "Keychain", so that one isn't searched.
    func matches(_ query: String) -> Bool {
        let query = query.lowercased()
        let fields = provider == KeychainProvider.id ? [title, username ?? ""] : [title, vaultName, username ?? ""]
        return query.isEmpty || fields.contains { $0.lowercased().contains(query) }
    }

    func ref(account: String) -> CredentialRef {
        CredentialRef(provider: provider, account: account, vault: vaultID, item: id, title: title, category: category, username: username)
    }
}

enum CredentialError: Error, Equatable, Sendable {
    case notInstalled, locked, notFound(String), noPassword(String), failed(String)

    static let invalidRef = CredentialError.failed("This credential link isn't valid. Choose it again.")

    /// One line, never contains secret material.
    var message: String {
        switch self {
        case .notInstalled: "1Password CLI (op) isn't installed."
        case .locked: "1Password is locked or not signed in."
        case .notFound(let title): "\"\(title)\" wasn't found in 1Password."
        case .noPassword(let title): "\"\(title)\" has no password."
        case .failed(let message): message
        }
    }
}

protocol CredentialProvider: Sendable {
    /// `account`: the user's chosen account id, if any.
    func status(account: String?) async -> ProviderStatus
    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem]
    func password(for ref: CredentialRef) async throws(CredentialError) -> String
    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String
}

/// Sends each call to the provider that owns the account or ref, so 1Password and Keychain refs
/// keep working side by side whichever one Settings picks for new credentials.
struct CredentialRouter: CredentialProvider {
    let onePassword: any CredentialProvider
    var keychain: any CredentialProvider = KeychainProvider()

    private func owner(_ account: String?) -> any CredentialProvider {
        account == KeychainProvider.id ? keychain : onePassword
    }

    func status(account: String?) async -> ProviderStatus { await owner(account).status(account: account) }

    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem] {
        try await owner(account).search(query, account: account)
    }

    func password(for ref: CredentialRef) async throws(CredentialError) -> String {
        try await owner(ref.provider).password(for: ref)
    }

    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String {
        try await owner(ref.provider).publicKey(for: ref)
    }
}
