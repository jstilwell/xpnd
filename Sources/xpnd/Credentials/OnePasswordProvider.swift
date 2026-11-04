import Foundation

struct OnePasswordProvider: CredentialProvider {
    typealias Run = @Sendable (URL, [String]) async -> ProcessOutput?

    private let opPath: String?
    private let run: Run

    init(opPath: String?, run: @escaping Run = OnePasswordProvider.defaultRun) {
        self.opPath = opPath
        self.run = run
    }

    /// 60 s so a Touch ID prompt has time.
    static let defaultRun: Run = { url, args in
        do { return try await ProcessRunner.run(url, arguments: args, timeoutMs: 60_000) }
        catch let e as ProcessRunError where e == .timedOut { return ProcessOutput(status: -1, stdout: "", stderr: "1Password took too long to respond.") }
        catch { return nil }
    }

    static func findOP(override: String?, isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ([override].compactMap { $0 } + ["/opt/homebrew/bin/op", "/usr/local/bin/op"]).first(where: isExecutable)
    }

    // MARK: argv builders

    static func accountListArguments() -> [String] { ["account", "list", "--format", "json"] }
    static func whoamiArguments(account: String) -> [String] { ["whoami", "--account", account, "--format", "json"] }
    static func listArguments(account: String) -> [String] {
        ["item", "list", "--account", account, "--categories", "Login,Password,SSH Key,Server", "--format", "json"]
    }
    static func fieldArguments(_ ref: CredentialRef, label: String) -> [String] {
        ["item", "get", ref.item, "--vault", ref.vault, "--account", ref.account, "--fields", "label=\(label)", "--reveal", "--format", "json"]
    }

    // MARK: provider

    func status() async -> ProviderStatus {
        guard let list = await exec(Self.accountListArguments()) else { return .notInstalled }
        let off = "Turn on 1Password's CLI integration (Settings > Developer) and sign in."
        guard list.status == 0, let accounts = Self.parseAccounts(list.stdout), let first = accounts.first else { return .notSignedIn(off) }
        guard let who = await exec(Self.whoamiArguments(account: first.id)) else { return .notInstalled }
        if who.status != 0 { return .notSignedIn(Self.firstLine(who.stderr) ?? "1Password is locked.") }
        return .ready(accounts)
    }

    func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem] {
        guard CredentialRef.isSafe(account) else { throw Self.invalidRef }
        let out = try await check(Self.listArguments(account: account), title: "")
        guard let data = out.stdout.data(using: .utf8),
              let rows = try? JSONDecoder().decode([Row].self, from: data) else { throw .failed("1Password returned an unexpected response.") }
        let q = query.lowercased()
        return rows.compactMap { $0.item }.filter {
            q.isEmpty || [$0.title, $0.vaultName, $0.username ?? ""].contains { $0.lowercased().contains(q) }
        }
    }

    func password(for ref: CredentialRef) async throws(CredentialError) -> String {
        try await field(ref, "password")
    }

    func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String {
        try await field(ref, "public key")
    }

    // MARK: helpers

    static let invalidRef = CredentialError.invalidRef

    private func exec(_ args: [String]) async -> ProcessOutput? {
        guard let path = Self.findOP(override: opPath) else { return nil }
        return await run(URL(fileURLWithPath: path), args)
    }

    private func field(_ ref: CredentialRef, _ label: String) async throws(CredentialError) -> String {
        guard CredentialRef.isSafe(ref.item), CredentialRef.isSafe(ref.vault), CredentialRef.isSafe(ref.account) else { throw Self.invalidRef }
        let out = try await check(Self.fieldArguments(ref, label: label), title: ref.title)
        struct Field: Decodable { let value: String? }
        let data = Data(out.stdout.utf8)
        // op may return an array when a label is duplicated; take the first.
        guard let f = (try? JSONDecoder().decode(Field.self, from: data)) ?? (try? JSONDecoder().decode([Field].self, from: data))?.first
        else { throw .failed("1Password returned an unexpected response.") }
        guard let v = f.value, !v.isEmpty else { throw .noPassword(ref.title) }
        return v
    }

    private func check(_ args: [String], title: String) async throws(CredentialError) -> ProcessOutput {
        guard let out = await exec(args) else { throw .notInstalled }
        if out.status == 0 { return out }
        // Only stderr is ever consulted; stdout may hold secrets.
        let err = out.stderr.lowercased()
        if err.contains("not currently signed in") || err.contains("authorization prompt dismissed")
            || err.contains("not signed in") { throw .locked }
        if err.contains("isn't an item") || err.contains("isn't a vault") { throw .notFound(title) }
        throw .failed(Self.firstLine(out.stderr) ?? "1Password failed.")
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(whereSeparator: \.isNewline).first.map { String($0.prefix(200)) }
    }

    private static func parseAccounts(_ json: String) -> [ProviderAccount]? {
        struct A: Decodable { let account_uuid: String; let email: String; let url: String }
        guard let data = json.data(using: .utf8), let a = try? JSONDecoder().decode([A].self, from: data) else { return nil }
        return a.map { ProviderAccount(id: $0.account_uuid, email: $0.email, url: $0.url) }
    }

    private struct Row: Decodable {
        struct Vault: Decodable { let id: String; let name: String }
        let id: String
        let title: String
        let category: String
        let vault: Vault
        let additional_information: String?

        var item: CredentialItem? {
            let c: CredentialCategory
            switch category {
            case "LOGIN": c = .login
            case "PASSWORD": c = .password
            case "SSH_KEY": c = .sshKey
            case "SERVER": c = .server
            default: return nil
            }
            return CredentialItem(id: id, vaultID: vault.id, vaultName: vault.name, title: title, category: c,
                                  username: c == .login ? additional_information : nil)
        }
    }
}
