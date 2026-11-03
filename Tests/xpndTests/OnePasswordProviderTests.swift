import Foundation
import Testing
@testable import xpnd

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [[String]] = []
    func add(_ a: [String]) { lock.lock(); list.append(a); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return list }
}

@Suite struct OnePasswordProviderTests {
    static let accounts = #"[{"url":"my.1password.com","email":"a@example.com","user_uuid":"U1","account_uuid":"ACC1"}]"#
    static let items = """
    [{"id":"i1","title":"Web Box","category":"LOGIN","additional_information":"root","vault":{"id":"v1","name":"Prod"}},
     {"id":"i2","title":"Wifi","category":"PASSWORD","additional_information":"x","vault":{"id":"v1","name":"Prod"}},
     {"id":"i3","title":"Deploy Key","category":"SSH_KEY","vault":{"id":"v2","name":"Keys"}},
     {"id":"i4","title":"DB Server","category":"SERVER","vault":{"id":"v2","name":"Keys"}},
     {"id":"i5","title":"Card","category":"CREDIT_CARD","vault":{"id":"v2","name":"Keys"}}]
    """

    private func provider(_ calls: Calls = Calls(), path: String? = "/fake/op",
                          reply: @escaping @Sendable ([String]) -> ProcessOutput?) -> OnePasswordProvider {
        OnePasswordProvider(opPath: path, run: { _, args in calls.add(args); return reply(args) })
    }

    private func out(_ stdout: String = "", _ stderr: String = "", status: Int32 = 0) -> ProcessOutput {
        ProcessOutput(status: status, stdout: stdout, stderr: stderr)
    }

    private let ref = CredentialRef(account: "ACC1", vault: "v1", item: "i1", title: "Web Box", category: .login)

    @Test func statusReadyParsesAccounts() async {
        let calls = Calls()
        // findOP needs an executable path; /bin/sh stands in so no real op is needed.
        let p = provider(calls, path: "/bin/sh") { args in args[0] == "account" ? self.out(Self.accounts) : self.out("{}") }
        #expect(await p.status() == .ready([ProviderAccount(id: "ACC1", email: "a@example.com", url: "my.1password.com")]))
        #expect(calls.all == [["account", "list", "--format", "json"], ["whoami", "--account", "ACC1", "--format", "json"]])
    }

    @Test func statusNotSignedIn() async {
        let p = provider(path: "/bin/sh") { args in args[0] == "account" ? self.out(Self.accounts) : self.out("", "boom", status: 1) }
        #expect(await p.status() == .notSignedIn("boom"))
        let empty = provider(path: "/bin/sh") { _ in self.out("[]") }
        if case .notSignedIn = await empty.status() {} else { Issue.record("expected notSignedIn") }
    }

    @Test func statusNotInstalled() async {
        let p = provider(path: "/bin/sh") { _ in nil }
        #expect(await p.status() == .notInstalled)
    }

    @Test func searchFiltersLocally() async throws {
        let calls = Calls()
        let p = provider(calls, path: "/bin/sh") { _ in self.out(Self.items) }
        let all = try await p.search("", account: "ACC1")
        #expect(all.map(\.title) == ["Web Box", "Wifi", "Deploy Key", "DB Server"])
        #expect(all.map(\.category) == [.login, .password, .sshKey, .server])
        #expect(all.map(\.username) == ["root", nil, nil, nil])
        #expect(try await p.search("ROOT", account: "ACC1").map(\.id) == ["i1"])
        #expect(try await p.search("keys", account: "ACC1").map(\.id) == ["i3", "i4"])
        #expect(try await p.search("wif", account: "ACC1").map(\.id) == ["i2"])
        #expect(calls.all[0] == ["item", "list", "--account", "ACC1", "--categories", "Login,Password,SSH Key,Server", "--format", "json"])
        #expect(all[0].ref(account: "ACC1") == CredentialRef(account: "ACC1", vault: "v1", item: "i1", title: "Web Box", category: .login, username: "root"))
    }

    @Test func passwordArguments() async throws {
        let calls = Calls()
        let p = provider(calls, path: "/bin/sh") { _ in self.out(#"{"id":"password","value":"  a,b\"c\n "}"#) }
        #expect(try await p.password(for: ref) == "  a,b\"c\n ")
        #expect(calls.all == [["item", "get", "i1", "--vault", "v1", "--account", "ACC1", "--fields", "label=password", "--reveal", "--format", "json"]])
    }

    @Test func emptyPasswordIsNoPassword() async throws {
        let p = provider(path: "/bin/sh") { _ in self.out(#"{"id":"password"}"#) }
        await #expect(throws: CredentialError.noPassword("Web Box")) { try await p.password(for: ref) }
        let e = provider(path: "/bin/sh") { _ in self.out(#"{"value":""}"#) }
        await #expect(throws: CredentialError.noPassword("Web Box")) { try await e.publicKey(for: ref) }
        let a = provider(path: "/bin/sh") { _ in self.out(#"[{"value":"first"},{"value":"second"}]"#) }
        #expect(try await a.password(for: ref) == "first")
        let bad = provider(path: "/bin/sh") { _ in self.out("hunter2") }
        do { _ = try await bad.password(for: ref); Issue.record("expected throw") }
        catch { #expect(!error.message.contains("hunter2")) }
    }

    @Test func publicKeyArguments() async throws {
        let calls = Calls()
        let p = provider(calls, path: "/bin/sh") { _ in self.out(#"{"value":"ssh-ed25519 AAAA"}"#) }
        #expect(try await p.publicKey(for: ref) == "ssh-ed25519 AAAA")
        #expect(calls.all == [["item", "get", "i1", "--vault", "v1", "--account", "ACC1", "--fields", "label=public key", "--reveal", "--format", "json"]])
    }

    @Test func stderrMapsToErrors() async {
        func err(_ stderr: String, stdout: String = "") -> OnePasswordProvider {
            provider(path: "/bin/sh") { _ in self.out(stdout, stderr, status: 1) }
        }
        await #expect(throws: CredentialError.locked) {
            try await err("[ERROR] 2026/01/01 You are not currently signed in.").password(for: ref)
        }
        await #expect(throws: CredentialError.notFound("Web Box")) {
            try await err(#"[ERROR] "i1" isn't an item in the "v1" vault."#).password(for: ref)
        }
        let secret = "hunter2-SECRET"
        do {
            _ = try await err("[ERROR] something odd\nsecond line", stdout: secret).password(for: ref)
            Issue.record("expected throw")
        } catch {
            #expect(error == .failed("[ERROR] something odd"))
            #expect(!error.message.contains(secret))
        }
        let missing = provider(path: "/bin/sh") { _ in nil }
        await #expect(throws: CredentialError.notInstalled) { try await missing.password(for: ref) }
    }

    @Test(arguments: ["--help", "--config=x", "-", "https://x", "", "a b", "é"])
    func unsafeRefsNeverRun(bad: String) async {
        let calls = Calls()
        let p = provider(calls, path: "/bin/sh") { _ in self.out(#"{"value":"x"}"#) }
        for r in [CredentialRef(account: "ACC1", vault: "v1", item: bad, title: "T", category: .login),
                  CredentialRef(account: "ACC1", vault: bad, item: "i1", title: "T", category: .login),
                  CredentialRef(account: bad, vault: "v1", item: "i1", title: "T", category: .login)] {
            await #expect(throws: OnePasswordProvider.invalidRef) { try await p.password(for: r) }
            await #expect(throws: OnePasswordProvider.invalidRef) { try await p.publicKey(for: r) }
        }
        await #expect(throws: OnePasswordProvider.invalidRef) { try await p.search("", account: bad) }
        #expect(calls.all.isEmpty)
    }

    @Test func findOPChecksOverrideFirst() {
        #expect(OnePasswordProvider.findOP(override: "/x/op", isExecutable: { _ in true }) == "/x/op")
        #expect(OnePasswordProvider.findOP(override: "/x/op", isExecutable: { $0 == "/usr/local/bin/op" }) == "/usr/local/bin/op")
        #expect(OnePasswordProvider.findOP(override: nil, isExecutable: { _ in false }) == nil)
    }
}
