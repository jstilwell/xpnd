# xpnd Connection Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn xpnd into a Dock app with a connection tree. Typing `;aws` connects over SSH (or VNC) in the user's terminal, `;prod` opens a numbered menu, and a hotkey opens a searchable connection launcher. Credentials come from 1Password and cascade global → folder → connection.

**Architecture:**
- **Data:** `connections.yaml` sits beside `snippets.yaml` behind the same file-safety core, generalized from `SnippetStore` into `YAMLFileStore<Value>`.
- **Pure core:** a connection model with a cascade resolver, a shared keyword namespace, an SSH command builder, a quick-menu model, and a connection filter. Each is tested in isolation.
- **Coordination:** `ConnectionService` resolves, builds, launches (by typing into the front terminal or running a launch plan), then copies passwords.
- **Engine:** `ExpansionEngine` matches activation strings next to snippets and gates each file separately.
- **UI:** the main window has a sidebar (Connections and Snippets) and a Details tab; Settings gains Terminal and Password manager sections.

**Tech Stack:** Swift 6.4, SwiftUI and AppKit, Swift Testing, the `op` CLI (1Password), NSAppleScript, and the existing Yams and Sparkle. No new packages.

**Spec:** `docs/superpowers/specs/2026-11-03-connection-manager-design.md` (binding). Prior spec: `docs/superpowers/specs/2026-11-03-text-expansion-design.md`.

## Global Constraints

- Work on branch `feature/connection-manager`, which already holds the spec. Commit after each task using Conventional Commits. Never use `--no-verify`.
- Swift 6 language mode, macOS 14 minimum, and the SwiftPM + Makefile layout already in the repo. Add no new dependencies.
- **Never log, store, or send secrets** (passwords, keys), typed keystrokes, buffer contents, or snippet text. HUD messages never contain secrets.
- `connections.yaml` lives at `~/Library/Application Support/xpnd/connections.yaml`. It has the same safety rules as `snippets.yaml`:
  - writes are atomic;
  - the app never overwrites a file it couldn't read or parse;
  - the app reloads on external edits and checks the disk before every save;
  - deleting the file recovers.
- Both stores share one implementation of those rules (Task 1), not two copies.
- Public keys go in `~/Library/Application Support/xpnd/keys/<item id>.pub`. Nothing secret is ever written to disk.
- Run commands with argv, never through a shell. The one exception is the user's own custom terminal template (`/bin/sh -c`), where `{command}` is substituted shell-quoted.
- Copied passwords use `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`. They are cleared after 30 s, but only if the clipboard still holds them (`changeCount`). xpnd never types a password into another app.
- Every connection action is subject to the front-app guard: if the app the string was typed in isn't still in front, nothing is typed. Only one expansion or connection action runs at a time.
- Snippet behaviour must not regress: every existing test keeps passing unchanged, except where a task says otherwise.
- Tests use Swift Testing (`import Testing`, `@testable import xpnd`). They are deterministic, with no fixed sleeps. They never call the real `op`, never open a real terminal, and never post real key events.
- `make app` builds after every task.

## Review Focus

1. **Hostile values in host, user, extra options, or a custom template** (spaces, quotes, `;`, `$(…)`) must be quoted, never executed, when typed into a terminal or run through the template. Test: Task 5 `hostileValuesAreQuoted`, Task 8 `templateQuotesCommand`.
2. **1Password missing, locked, integration off, or item deleted** must give a one-line message. For key logins the command is still typed, because passwords come after. Nothing is ever half-typed. Tests: Task 6 `stderrMapsToErrors`, Task 12 `providerFailureAfterTyping`.
3. **A hand-edited `connections.yaml` with a jump host pointing at a deleted connection or forming a cycle** (A→B→A) must give a builder error, not a crash or infinite recursion. Test: Task 5 `jumpCycleAndMissing`.
4. **An activation string typed while a snippet expansion or another connection is running, or typed twice fast,** must never interleave pastes. Test: Task 9 `activationWhileBusyIsIgnored`.
5. **Folder names with spaces, capitals, emoji, or duplicates in different branches** must derive sensibly (`My Servers` → `;myservers`). The first folder in tree order keeps a contested derived string, and later ones get none. Test: Task 3 `derivedActivationEdgeCases`.

---

## Stage 1: Data and namespace
**Goal**: The connections file, model, cascade, and shared keyword namespace, all tested.
**Success Criteria**: `make test` is green, including all existing snippet tests, with the new model, store, cascade, and namespace tests.
**Tests**: YAMLFileStoreTests (existing SnippetStoreTests rerun), ConnectionYAMLTests, ConnectionLibraryTests, KeywordNamespaceTests, ConnectionImportTests
**Status**: Not Started

### Task 1: Generalize the file store

**Files:**
- Create: `Sources/xpnd/Library/YAMLFileStore.swift`
- Modify: `Sources/xpnd/Library/SnippetStore.swift` (becomes a thin specialization), every `SnippetStore` user that breaks
- Test: `Tests/xpndTests/SnippetStoreTests.swift` (unchanged; it must still pass)

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class YAMLFileStore<Value: Sendable & Equatable>`, with:
    - `init(fileURL: URL, empty: Value, decode: @escaping (String) throws -> Value, encode: @escaping (Value) -> String, duplicate: @escaping (Value) -> String?)`
    - `private(set) var value: Value`, `private(set) var loadError: String?`
    - `func load()`, `func update(_ change: (inout Value) -> Void) throws(StoreError)`, `func startWatching()`, `func stopWatching()`
    - `var fileExists: Bool`
  - `typealias SnippetStore = YAMLFileStore<SnippetLibrary>`, with `extension YAMLFileStore where Value == SnippetLibrary` providing:
    - `convenience init(fileURL: URL)`
    - `nonisolated static var defaultURL: URL`
    - `var library: SnippetLibrary { value }`
  - `StoreError` is unchanged.

- [ ] **Step 1: Move the code.** Move `SnippetStore`'s body into `YAMLFileStore` verbatim, swapping `SnippetYAML.decode/encode` and `duplicateKeywords.first` for the closures. Keep every comment and every guard: the empty-encode refusal for a non-empty value becomes "encode returned empty text while `value != empty`".
- [ ] **Step 2: Build and test.** Run `xcrun swift test`. Expected: all tests pass with no test-file edits.
- [ ] **Step 3: Commit.** `refactor(library): share the YAML file-safety core between stores`

### Task 2: Connection model and YAML codec

**Files:**
- Create: `Sources/xpnd/Connections/Connection.swift`, `Sources/xpnd/Connections/ConnectionYAML.swift`
- Test: `Tests/xpndTests/ConnectionYAMLTests.swift`

**Interfaces:**
- Produces:
  - `enum ConnectionType: String, Codable, Sendable { case ssh, vnc }`, with `var defaultPort: Int` (22, 5900)
  - `enum CredentialCategory: String, Codable, Sendable { case sshKey = "ssh_key", login, password, server }`
  - `struct CredentialRef: Hashable, Codable, Sendable { var provider = "1password"; var account: String; var vault: String; var item: String; var title: String; var category: CredentialCategory; var username: String? }`, with `var hasPassword: Bool { category != .sshKey }`
  - `enum JumpHost: Hashable, Sendable { case connection(UUID), text(String) }`
  - `struct Connection: Identifiable, Hashable, Sendable`, with fields:
    - `var id = UUID()`, `var name: String`, `var type: ConnectionType = .ssh`, `var host: String`
    - `var port: Int?`, where nil means the type's default; `var effectivePort: Int`
    - `var username: String?`, `var activation: String?`
    - `var credential: CredentialRef?`, `var sudoCredential: CredentialRef?`
    - `var jumpHost: JumpHost?`, `var sshOptions = ""`, `var autoSudo = false`
  - `struct ConnectionFolder: Identifiable, Hashable, Sendable { var id = UUID(); var name: String; var activation: String?; var credential: CredentialRef?; var sudoCredential: CredentialRef?; var connections: [Connection] = []; var folders: [ConnectionFolder] = [] }`. A nil `activation` means derived; `""` means none.
  - `struct ConnectionLibrary: Hashable, Sendable { var credential: CredentialRef?; var sudoCredential: CredentialRef?; var folders: [ConnectionFolder] }`, with:
    - `static let empty`
    - `static func starter() -> ConnectionLibrary`, which returns empty `dev` and `prod` folders with derived activation and fresh IDs
  - `enum ConnectionYAML { static func decode(_: String) throws(ConnectionYAMLError) -> ConnectionLibrary; static func encode(_: ConnectionLibrary) -> String }`
  - `enum ConnectionYAMLError: Error, Equatable { case malformed(String), unsupportedVersion(Int), duplicateIDs([String]) }`
  - YAML shape: exactly the spec's schema. `advanced:` holds `jumpHost` (`{connection: <uuid>}` or `{text: …}`), `sshOptions`, and `autoSudo`. Optional fields are omitted when nil, empty, or default. Folder `activation` is omitted when nil.

- [ ] **Step 1: Write failing tests:**
  - `decodesSpecExample()`: folder prod with activation nil; aws has port 22, `jumpHost == .connection(…)`, and `autoSudo == true`.
  - `roundTripsWithIDs()`: IDs, nesting, both jump-host forms, and a credential with username survive the round trip.
  - `defaultsOmitted()`: a connection with port nil, no options, and autoSudo false encodes without `port`, `advanced`, or `activation`.
  - `emptyActivationIsNone()`: `activation: ""` decodes to `""`, distinct from nil.
  - `malformedAndVersion()` covers `.malformed` and `.unsupportedVersion(2)`.
  - `duplicateIDsThrow()`
  - `starterHasDevAndProd()`
- [ ] **Step 2: Run them and see them fail.** `xcrun swift test --filter ConnectionYAMLTests`
- [ ] **Step 3: Implement** with private Codable DTOs, as `SnippetYAML` does. Missing `version` is treated as 1. Use literal style for multi-line strings.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit.** `feat(connections): add connection model and YAML format`

### Task 3: Tree queries, cascade, and the shared namespace

**Files:**
- Create: `Sources/xpnd/Connections/ConnectionLibrary+Tree.swift`, `Sources/xpnd/Library/KeywordNamespace.swift`
- Modify: `Sources/xpnd/Library/KeywordValidation.swift` only if needed. Its messages and tests stay as they are.
- Test: `Tests/xpndTests/ConnectionLibraryTests.swift`, `Tests/xpndTests/KeywordNamespaceTests.swift`

**Interfaces:**
- Produces:
  - `extension ConnectionFolder { static func derivedActivation(for name: String) -> String }`. The result is `";"` followed by the name lowercased, with whitespace removed and other characters kept; an empty result means none.
  - `extension ConnectionLibrary`, with:
    - lookups: `func connection(_ id: Connection.ID) -> Connection?`, `func folder(_ id: ConnectionFolder.ID) -> ConnectionFolder?`
    - `func path(of id: Connection.ID) -> [ConnectionFolder]`, ancestors from the root
    - `var allConnections: [Connection]`, in tree order: a folder's connections, then its subfolders, depth-first
    - `func loginCredential(for id: Connection.ID) -> ResolvedCredential?`
    - `func sudoCredential(for id: Connection.ID) -> ResolvedCredential?`
  - `struct ResolvedCredential: Equatable { let ref: CredentialRef; let source: CredentialSource }`
  - `enum CredentialSource: Equatable { case connection, folder(name: String), global, login }`, where `.login` means the sudo credential fell back to the login credential
  - `enum ActivationTarget: Hashable, Sendable { case connection(Connection.ID), folder(ConnectionFolder.ID) }`
  - `struct KeywordNamespace`, with:
    - `init(snippets: SnippetLibrary, connections: ConnectionLibrary)`
    - `enum Owner: Hashable { case snippet(Snippet.ID), folder(ConnectionFolder.ID), connection(Connection.ID) }`
    - `func problem(_ string: String, for owner: Owner?) -> String?`
    - `func effectiveActivation(ofFolder id: ConnectionFolder.ID) -> (string: String?, reason: String?)`
    - `var activations: [String: ActivationTarget]`
    - `var crossFileDuplicates: Set<String>`

- [ ] **Step 1: Write failing tests:**
  - **Cascade:**
    - `loginCascade()`: override beats nearest folder, which beats an ancestor folder, which beats global, which beats nil; sources are reported correctly.
    - `sudoCascade()`: connection, then folder, then global sudo, then the login credential (`.login`) only if `hasPassword`; key-only login with no sudo gives nil.
  - **Tree:**
    - `treeOrder()`
    - `pathOfNested()`
  - **Namespace:**
    - `derivedActivationEdgeCases()`: `My Servers` gives `;myservers`, and the emoji is kept. In `dev/web` and `prod/web`, the first in tree order gets `;web` and the second gets nil, with reason "“;web” is already used by folder “web”". A snippet `;dev` makes folder dev's effective activation nil, with a reason. A custom `""` is none.
    - `problemMessages()`:
      - Format rules come from the existing `keywordProblem` messages.
      - Owners are named "“;dev” is already used by folder “dev”", "… by connection “aws”", or the existing "… by “Signature”" for a snippet.
      - Checking `;dev` for the folder that already owns it returns nil.
    - `crossFileDuplicatesTriggerNothing()`: a snippet `;x` and a connection `;x` (a hand edit) put `;x` in `crossFileDuplicates` and leave it out of `activations`.
    - `activationsMap()`: covers connection strings and effective folder strings.
- [ ] **Step 2: Run them and see them fail.** `xcrun swift test --filter "ConnectionLibraryTests|KeywordNamespaceTests"`
- [ ] **Step 3: Implement.** Snippet keywords take precedence over derived folder strings; custom strings are never silently dropped, only flagged when duplicated.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit.** `feat(connections): resolve credentials and share the keyword namespace`

### Task 4: Connection store, first-launch seeding, and import

**Files:**
- Create: `Sources/xpnd/Connections/ConnectionStore.swift`, `Sources/xpnd/Connections/ConnectionImport.swift`
- Test: `Tests/xpndTests/ConnectionStoreTests.swift`, `Tests/xpndTests/ConnectionImportTests.swift`

**Interfaces:**
- Produces:
  - `typealias ConnectionStore = YAMLFileStore<ConnectionLibrary>`, extended with:
    - `convenience init(fileURL: URL)`, using `duplicate:` = the first duplicate ID
    - `nonisolated static var defaultURL: URL`
    - `var library: ConnectionLibrary { value }`
    - `func seedIfFirstLaunch(defaults: UserDefaults)`, with the defaults key `connectionsSeeded`
  - `enum ConnectionImport`, with:
    - `static func conflicts(incoming:, existing:) -> [String]`, the activation strings
    - `static func merge(_:into:choice: ConflictChoice) -> ConnectionLibrary`
    - `static func hostsAdded(incoming:, existing:) -> [String]`
    - `static func export(_:folders: Set<ConnectionFolder.ID>?) -> String`

- [ ] **Step 1: Write failing tests** (temporary directory, a fresh `UserDefaults(suiteName:)`):
  - `seedsOnceOnFirstLaunch()`: the file is missing and the flag unset, so dev and prod are written and the flag set. Deleting the file and seeding again writes nothing.
  - `doesNotSeedOverExistingFile()`
  - `storeRoundTrip()`
  - `malformedNeverOverwritten()`, a smoke check of the shared core with this value type.
  - Import:
    - `mergeByFolderName()`
    - `skipReplaceOnActivationConflict()`
    - `idsKeptUnlessColliding()`: a colliding ID gets a fresh UUID, and jump references inside the import are rewritten to match.
    - `hostsAddedListed()`
    - `exportSelectedFoldersRoundTrips()`
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit.** `feat(connections): add the connections store, first-launch folders, and import`

---

## Stage 2: Connecting
**Goal**: Everything needed to connect, as pure or fakeable code: the command builder, the 1Password provider, the secret clipboard, the launch planner and executor, and the connect service.
**Success Criteria**: The full connect flow is tested end to end with fakes. No real `op`, terminal, or key events.
**Tests**: SSHCommandTests, OnePasswordProviderTests, SecretClipboardTests, LaunchPlannerTests, ConnectionServiceTests
**Status**: Not Started

### Task 5: SSH command builder and shell quoting

**Files:**
- Create: `Sources/xpnd/Connections/ShellQuote.swift`, `Sources/xpnd/Connections/SSHCommand.swift`
- Test: `Tests/xpndTests/SSHCommandTests.swift`

**Interfaces:**
- Produces:
  - `enum ShellQuote`, with:
    - `static func quote(_ s: String) -> String`, a POSIX single-quote form; safe characters are left bare
    - `static func split(_ s: String) throws(SSHCommandError) -> [String]`, shell-style splitting with quotes and backslashes
  - `enum SSHCommandError: Error, Equatable`, with cases `unbalancedQuote`, `jumpHostMissing`, `jumpHostCycle`, `jumpHostNeedsKey(String)`, `notSSH` and `var message: String`
  - `struct SSHCommand: Equatable { let arguments: [String]; var shellLine: String }`. `arguments[0] == "ssh"`, and `shellLine` is the quoted arguments joined by spaces.
  - `enum SSHCommandBuilder`, with:
    - `static let agentSocket = "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"`
    - `static func build(_ id: Connection.ID, in library: ConnectionLibrary, keysDirectory: URL) throws(SSHCommandError) -> SSHCommand`

- [ ] **Step 1: Write failing tests:**
  - `plainConnection()`: host only, port 22, no credential gives `["ssh", "54.242.245.93"]`.
  - `portAndUser()`: port 2222 with an override user gives `-p 2222` and `ubuntu@host`; the credential username is used when there's no override.
  - `sshKeyCredential()`: adds `-o IdentityAgent=<agentSocket>`, `-o IdentitiesOnly=yes`, and `-i <keysDirectory>/<item>.pub`.
  - `passwordCredential()`: adds `-o PubkeyAuthentication=no` and no agent options.
  - `extraOptionsSplit()`: `-o "ProxyJump=none" -v` gives three arguments; an unbalanced quote throws `.unbalancedQuote`.
  - `autoSudo()`: gives `-t`, then the target, then `sudo`, `-i`.
  - `jumpText()`: gives `-J ec2-user@bastion:22`.
  - `jumpSavedConnection()`: gives `-o ProxyCommand=<…>`. Its value is the jump host's own key options plus `-W %h:%p user@jump`, with each part quoted.
  - `jumpCycleAndMissing()`: A→B→A throws `.jumpHostCycle`, and a deleted ID throws `.jumpHostMissing`.
  - `jumpPasswordRefused()`: throws `.jumpHostNeedsKey("bastion")`.
  - `hostileValuesAreQuoted()`: with host `a;rm -rf ~`, user `$(id)`, and option `'x y'`, `shellLine` round-trips through `ShellQuote.split` back to `arguments`.
- [ ] **Step 2: Run them and see them fail.** `xcrun swift test --filter SSHCommandTests`
- [ ] **Step 3: Implement.** Argument order: `ssh`, `-p`, jump, credential options, extra options, `-t`, target, remote command.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit.** `feat(connections): build ssh commands with 1Password keys and jump hosts`

### Task 6: Credential provider and 1Password

**Files:**
- Create: `Sources/xpnd/Credentials/CredentialProvider.swift`, `Sources/xpnd/Credentials/OnePasswordProvider.swift`
- Modify: `Sources/xpnd/Expansion/ProcessRunner.swift` (capture stderr) and its callers (`ScriptRunner`, `ActionRunner`, `ShortcutsList`, tests)
- Test: `Tests/xpndTests/OnePasswordProviderTests.swift`, with JSON fixtures inline in the test file

**Interfaces:**
- Produces:
  - `struct ProcessOutput: Sendable, Equatable { let status: Int32; let stdout: String; let stderr: String }`. `ProcessRunner.run` returns it; stderr is drained like stdout.
  - `struct ProviderAccount: Hashable, Sendable { let id: String; let email: String; let url: String }`
  - `enum ProviderStatus: Equatable, Sendable { case notInstalled, notSignedIn(String), ready([ProviderAccount]) }`
  - `struct CredentialItem: Hashable, Sendable { let id: String; let vaultID: String; let vaultName: String; let title: String; let category: CredentialCategory; let username: String? }`, with `func ref(account: String) -> CredentialRef`
  - `enum CredentialError: Error, Equatable, Sendable`, with cases `notInstalled`, `locked`, `notFound(String)`, `noPassword(String)`, `failed(String)` and `var message: String`
  - `protocol CredentialProvider: Sendable`, with:
    - `func status() async -> ProviderStatus`
    - `func search(_ query: String, account: String) async throws(CredentialError) -> [CredentialItem]`
    - `func password(for ref: CredentialRef) async throws(CredentialError) -> String`
    - `func publicKey(for ref: CredentialRef) async throws(CredentialError) -> String`
  - `struct OnePasswordProvider: CredentialProvider`, with:
    - `init(opPath: String?, run: @escaping @Sendable (URL, [String]) async -> ProcessOutput?)`. `run` returns nil when the executable is missing. The default `run` is `ProcessRunner` with a 60 000 ms timeout, so a Touch ID prompt has time.
    - `static func findOP(override: String?) -> String?`, which checks the override, then `/opt/homebrew/bin/op`, then `/usr/local/bin/op`.

- [ ] **Step 1: Write failing tests** using a fake `run` that records arguments and returns fixtures:
  - `statusReadyParsesAccounts()` (`op account list --format json`)
  - `statusNotInstalled()`
  - `searchFiltersLocally()`: the fake returns `op item list --format json` for Login, Password, SSH Key, and Server items; the query matches title, vault, or username case-insensitively; categories map to `CredentialCategory`; the username comes from `additional_information` for logins.
  - `passwordArguments()`: asserts the exact argv for reading a password by item, vault, and account IDs, and that stdout's trailing newline is trimmed.
  - `publicKeyArguments()`
  - `stderrMapsToErrors()`: fixtures for "not currently signed in", "isn't an item", and a generic failure map to `.locked`, `.notFound(title)`, and `.failed`. No secret ever appears in `message`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** Verify exact `op` flags with `op <command> --help` only. Never run commands that touch the user's account. Put the argv builders in one place.
- [ ] **Step 4: Run them, plus the full suite (ProcessRunner callers changed), and see them pass.**
- [ ] **Step 5: Commit.** `feat(credentials): read 1Password items through op`

### Task 7: Secret clipboard

**Files:**
- Create: `Sources/xpnd/Credentials/SecretClipboard.swift`
- Test: `Tests/xpndTests/SecretClipboardTests.swift`

**Interfaces:**
- Produces: `@MainActor enum SecretClipboard`, with:
  - `static let clearAfter: Duration = .seconds(30)`
  - `@discardableResult static func copy(_ secret: String, to pasteboard: NSPasteboard = .general, clearAfter: Duration = clearAfter) -> Task<Void, Never>`

- [ ] **Step 1: Write failing tests** on a uniquely named private pasteboard with `clearAfter` of 50 ms, awaiting the returned task:
  - `copiesWithMarkers()`: the string plus the concealed and transient types are present.
  - `clearsWhenUnchanged()`
  - `keepsNewerCopy()`: something else written before the clear survives.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit.** `feat(credentials): copy secrets with concealed markers and auto-clear`

### Task 8: Terminal settings, launch planner, and executor

**Files:**
- Create: `Sources/xpnd/Connections/TerminalSettings.swift`, `Sources/xpnd/Connections/LaunchPlanner.swift`, `Sources/xpnd/Connections/LaunchExecutor.swift`, `xpnd.entitlements`
- Modify: `Resources/Info.plist` (`NSAppleEventsUsageDescription`), `Makefile` (sign the app with `--entitlements xpnd.entitlements`), `Sources/xpnd/App/AppSettings.swift` (`terminal: TerminalSettings`, stored as JSON under `terminalSettings`)
- Test: `Tests/xpndTests/LaunchPlannerTests.swift`

**Interfaces:**
- Produces:
  - `enum TerminalPreset: String, Codable, CaseIterable, Sendable`, with cases `terminal`, `iterm2`, `ghostty` and properties `bundleID`, `displayName`, `supportsTabs`. Add `warp` only if Step 3 shows it can run a command reliably; otherwise Settings mentions it next to the custom option.
  - `enum NoTerminalAction: Codable, Hashable, Sendable { case preset(TerminalPreset, newTab: Bool), custom(template: String) }`
  - `struct TerminalSettings: Codable, Hashable, Sendable { var terminalBundleIDs: [String]; var whenNoTerminal: NoTerminalAction; static let standard }`. The standard value lists the bundle IDs for Terminal, iTerm2, Ghostty, and Warp, and opens a new Terminal window.
  - `enum LaunchPlan: Equatable, Sendable`, with cases:
    - `typeIntoFrontTerminal(String)`
    - `appleScript(String)`
    - `run(executable: String, arguments: [String])`
    - `openURL(URL)`
  - `enum LaunchPlanner`, with:
    - `static func plan(_ command: SSHCommand, frontBundleID: String?, settings: TerminalSettings) -> LaunchPlan`
    - `static func vncURL(host: String, port: Int, user: String?) -> URL`
  - `@MainActor protocol LaunchExecuting { func execute(_ plan: LaunchPlan) async throws(LaunchError) }`
  - `enum LaunchError: Error, Equatable { case appleScriptDenied, appleScriptFailed(String), appMissing(String), failed(String); var message: String }`
  - `@MainActor struct LiveLaunchExecutor: LaunchExecuting`. It runs AppleScript with `NSAppleScript`, `run` plans with `ProcessRunner`, and URLs with `NSWorkspace`. `typeIntoFrontTerminal` isn't handled here; `ConnectionService` types it.

- [ ] **Step 1: Write failing tests:**
  - `terminalInFrontTypes()`: a front bundle ID on the list gives `.typeIntoFrontTerminal(command.shellLine)`.
  - `presetTerminalScript()` and `presetITermScript()`: the AppleScript contains the command quoted for AppleScript, so `"` and `\` are escaped.
  - `presetGhostty()`: gives `.run` with `open -na Ghostty.app --args -e …`, or whatever Step 3 confirms.
  - `templateQuotesCommand()`: template `tmux new-window {command}` gives `.run("/bin/sh", ["-c", "tmux new-window '<quoted shellLine>'"])`, and a hostile host can't break out.
  - `templateWithoutPlaceholder()`: gives the template with the quoted command appended.
  - `vncURLEncodesUser()`
  - `settingsRoundTrip()` through `AppSettings` with a suite `UserDefaults`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement, then check each preset by hand.** Run `osascript` and `open` manually against Terminal, iTerm2 (if installed), Ghostty (if installed), and Warp. Record in the report what works. Add `com.apple.security.automation.apple-events` to `xpnd.entitlements`, and the usage string: "xpnd opens your SSH connections in Terminal or iTerm2."
- [ ] **Step 4: Run the tests and `make app`, then confirm with `codesign -d --entitlements - build/xpnd.app` that the entitlement is present.**
- [ ] **Step 5: Commit.** `feat(connections): plan and run terminal launches`

### Task 9: Engine activation strings

**Files:**
- Modify: `Sources/xpnd/Expansion/ExpansionEngine.swift`, `Sources/xpnd/App/AppDelegate.swift` (construction)
- Test: `Tests/xpndTests/ExpansionEngineTests.swift` (new cases; existing cases updated only where init arguments change)

**Interfaces:**
- Consumes: `KeywordNamespace` (Task 3) and `ConnectionStore` (Task 4).
- Produces:
  - `ExpansionEngine.init` gains `connections: ConnectionStore` and `onActivate: @escaping @MainActor (ActivationTarget, pid_t?) async -> Void`.
  - `func exclusive(_ body: @MainActor () async -> Void) async -> Bool`. It returns false without running `body` if busy. While `body` runs, `isExpanding` is true.

- [ ] **Step 1: Write failing tests:**
  - `connectionStringActivates()`: typing `;aws` gives the log `["bs 4"]`, then `onActivate(.connection(id), targetPID)`.
  - `folderStringActivates()`: gives `.folder(id)`.
  - `longestWinsAcrossBoth()`: a loose snippet `v` and a folder `;dev`, with buffer `;dev`, picks the folder.
  - `perFileGating()`: when the connections store has a loadError, snippets still expand and activations don't; and the reverse.
  - `crossFileDuplicateDoesNothing()`
  - `activationWhileBusyIsIgnored()`: while a snippet's input form is suspended, typing `;aws` does nothing, and `exclusive` returns false.
  - `frontAppChangedCancelsActivation()`: no `onActivate`, and the notify message is `targetAppChanged`.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.**
  - A snippet match uses only snippets whose file is OK, minus cross-file duplicates. An activation match uses `KeywordNamespace.activations`, only when the connections file is OK, as an exact buffer match.
  - Delete the typed string with `player.play([], deletingCharacters: count)`, check the front app, then `await onActivate`, all inside the same exclusive claim.
- [ ] **Step 4: Run the full suite and see it pass.**
- [ ] **Step 5: Commit.** `feat(expansion): trigger connections and folders from activation strings`

### Task 10: Connect service

**Files:**
- Create: `Sources/xpnd/Connections/ConnectionService.swift`, `Sources/xpnd/App/PasswordPrompt.swift`
- Test: `Tests/xpndTests/ConnectionServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 3 and 5–9.
- Produces:
  - `@MainActor protocol PasswordPrompting { func offerSudo(for name: String) async -> Bool }`. The live version is a small non-activating panel with a "Copy sudo password" button; it returns false after 60 s or when dismissed.
  - `@MainActor final class ConnectionService`, with:
    - `init(connections: ConnectionStore, provider: any CredentialProvider, executor: any LaunchExecuting, sender: any KeystrokeSending, terminal: @escaping @MainActor () -> TerminalSettings, frontmost: @escaping @MainActor () -> (pid: pid_t, bundleID: String?)?, notify: @escaping @MainActor (String) -> Void, copySecret: @escaping @MainActor (String) -> Void, prompt: any PasswordPrompting, keysDirectory: URL)`
    - `func connect(_ id: Connection.ID, typedInto target: pid_t?) async`

- [ ] **Step 1: Write failing tests**, all with fakes:
  - `keyLoginTypesIntoTerminal()`: with a terminal in front, the sender log is `["paste <shellLine>", "key enter x1"]` and the provider is never called.
  - `passwordLoginCopiesAfterTyping()`: the event order is typing, then `provider.password`, then `copySecret`, then notify "Password copied for aws".
  - `loginThenSudo()`: copies the login password, then calls `prompt.offerSudo`; if it returns true, copies the sudo password.
  - `sudoOnlyCopiesDirectly()`
  - `noSudoPasswordMessage()`: key login with autoSudo and no sudo credential notifies "No sudo password set for aws".
  - `noTerminalRunsPlan()`: calls `executor.execute(.appleScript…)`.
  - `vncOpensURLAndCopies()`
  - `builderErrorNotifies()`: a jump cycle produces nothing typed and only the message.
  - `providerFailureAfterTyping()`: `.locked` when fetching the password leaves the command typed and gives exactly one message.
  - `frontAppGuard()`: when `target` differs from the current frontmost, nothing is typed and the message is `targetAppChanged`.
  - `missingPublicKeyIsFetched()`: if the `.pub` file is absent, `publicKey(for:)` is called and the file written before building. The front app is then checked again.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** Type with the sender: paste `shellLine`, then press `.enter`.
- [ ] **Step 4: Run them and see them pass.**
- [ ] **Step 5: Commit.** `feat(connections): connect, then copy passwords`

---

## Stage 3: Launch surfaces and window
**Goal**: The quick menu, the connection launcher, the Dock app with the main window and editors, and the new Settings sections, all wired in the AppDelegate.
**Success Criteria**: `make run` shows the Dock icon and main window. `;dev` shows the quick menu, ⌃⌥⌘C shows the launcher, and connecting works in Terminal. Unit tests are green. The manual checklist is handed to the user.
**Tests**: QuickMenuModelTests, ConnectionFilterTests, AppSettings shortcut tests, and the manual checklist
**Status**: Not Started

### Task 11: Shared launcher panel and quick menu

**Files:**
- Create: `Sources/xpnd/Picker/LauncherPanel.swift` (extracted from `PickerPanel`: `KeyablePanel`, centering, close on resign, previous-app capture, refocus), `Sources/xpnd/Connections/QuickMenuModel.swift`, `Sources/xpnd/Connections/QuickMenuPanel.swift`
- Modify: `Sources/xpnd/Picker/PickerPanel.swift` to use `LauncherPanel`, with no behavior change
- Test: `Tests/xpndTests/QuickMenuModelTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor class LauncherPanel`, with:
    - `func present(_ view: some View)`
    - `func close()`
    - `var previousApp: NSRunningApplication?`
    - `func refocusPrevious() async -> pid_t?`, which waits up to 1 s and returns the frontmost pid afterwards
  - `struct QuickMenuRow: Hashable { enum Kind: Hashable { case connection(Connection.ID, ConnectionType), folder(ConnectionFolder.ID) }; let number: Int?; let title: String; let kind: Kind }`
  - `struct QuickMenuModel`, with:
    - `init(library: ConnectionLibrary, folder: ConnectionFolder.ID)`
    - `var title: String`, `var rows: [QuickMenuRow]`, `var canGoBack: Bool`
    - `func row(number: Int) -> QuickMenuRow?`
    - `mutating func choose(_ row: QuickMenuRow) -> Connection.ID?`, which opens a folder in place and returns nil
    - `mutating func back()`
  - `@MainActor final class QuickMenuPanel: LauncherPanel`, with `func show(folder: ConnectionFolder.ID, library: ConnectionLibrary, connect: @escaping (Connection.ID, pid_t?) async -> Void)`

- [ ] **Step 1: Write failing tests:**
  - `numbersFirstNine()`: connections first, then subfolders, each numbered 1–9; the tenth and later have nil numbers.
  - `digitPicks()`
  - `subfolderAndBack()`
  - `emptyFolder()`: `rows.isEmpty`, and the title is the folder name.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement the model, `LauncherPanel`, and `QuickMenuPanel`.**
  - Digits pick a row; ↑/↓ and Return move and choose; ← goes back; Esc and losing focus close the panel.
  - An empty folder shows "No connections in <name> yet" and an "Open xpnd" button.
  - The picker keeps working, and the existing PickerFilterTests pass.
- [ ] **Step 4: Run the full suite and `make app`.**
- [ ] **Step 5: Commit.** `feat(connections): numbered quick menu for folder activation strings`

### Task 12: Connection launcher and both hotkeys

**Files:**
- Create: `Sources/xpnd/Connections/ConnectionFilter.swift`, `Sources/xpnd/Connections/ConnectionLauncherPanel.swift`
- Modify: `Sources/xpnd/App/AppSettings.swift` (`connectionLauncherShortcut`), `Sources/xpnd/Settings/GeneralSettingsView.swift` (two recorders, labelled "Snippet picker" and "Connection launcher"), `Sources/xpnd/App/AppDelegate.swift` (second hotkey, re-registered on change, same "in use" message)
- Test: `Tests/xpndTests/ConnectionFilterTests.swift`, `Tests/xpndTests/AppSettingsTests.swift`

**Interfaces:**
- Produces:
  - `struct ConnectionEntry: Hashable { let connection: Connection; let path: [String]; var pathText: String }`. `pathText` joins names with " › ".
  - `enum ConnectionFilter`, with:
    - `static func entries(_ library: ConnectionLibrary) -> [ConnectionEntry]`, in tree order
    - `static func filter(_ entries: [ConnectionEntry], query: String) -> [ConnectionEntry]`
  - `AppSettings`:
    - `static let defaultConnectionLauncherShortcut = Shortcut(keyCode: 8, modifiers: [.control, .option, .command], key: "C")`
    - `var connectionLauncherShortcut: Shortcut?`, stored under `connectionLauncherShortcut`
  - `@MainActor final class ConnectionLauncherPanel: LauncherPanel`, with `func toggle(library: ConnectionLibrary, connect: @escaping (Connection.ID, pid_t?) async -> Void)`

- [ ] **Step 1: Write failing tests:**
  - `rankNamePrefixFirst()`: name prefix, then name, string, or host contains, then folder-path match; ties go by name.
  - `matchesFolderPath()`: `prod` finds every connection under prod.
  - `caseAndDiacriticInsensitive()`
  - `treeOrderWhenEmpty()`
  - `shortcutsPersistIndependently()`: suite defaults; both defaults are present; changing one leaves the other unchanged.
- [ ] **Step 2: Run them and see them fail.**
- [ ] **Step 3: Implement.** With no query, the panel shows an indented tree (→ and ← expand and collapse); with a query, a flat list with `pathText`. Return connects, relative to `refocusPrevious()`.
- [ ] **Step 4: Run the full suite and `make app`.**
- [ ] **Step 5: Commit.** `feat(connections): searchable connection launcher on its own hotkey`

### Task 13: Dock app and main window shell

**Files:**
- Create: `Sources/xpnd/Main/MainWindowController.swift`, `Sources/xpnd/Main/Sidebar.swift`, `Sources/xpnd/Main/DetailsPane.swift`
- Modify:
  - `Resources/Info.plist`: `LSUIElement` false.
  - `Sources/xpnd/main.swift`: start `.regular` unless launched as a login item; detecting that is the builder's call, e.g. `keyAELaunchedAsLogInItem`.
  - `Sources/xpnd/App/AppDelegate.swift`:
    - "Open xpnd…" in the menu bar, and Dock reopen
    - `.accessory` when the last main window closes, `.regular` when one opens
    - wire `ConnectionStore` (load, watch, seed), `ConnectionService`, the quick menu, and the launcher into `onActivate`
  - `Sources/xpnd/Settings/SettingsWindow.swift`: remove the `snippets` section.
  - `Sources/xpnd/Settings/SnippetsSettingsView.swift`: reshape into a snippets sidebar section plus a Details editor, reusing `SnippetEditorView` and `TemplateTextView` unchanged.

**Interfaces:**
- Produces:
  - `enum SidebarItem: Hashable { case folder(ConnectionFolder.ID), connection(Connection.ID), snippetGroup(SnippetGroup.ID), snippet(Snippet.ID) }`
  - `@MainActor final class MainWindowController: NSWindowController`, with `func show(selecting: SidebarItem?)`

- [ ] **Step 1: Build the shell.**
  - A `NavigationSplitView` sidebar with sections **Connections** (an outline of folders and connections, each folder showing its effective activation) and **Snippets** (groups as one-level folders with their on/off switch).
  - The Details tab strip on the right, holding the snippet editor and placeholders for folder and connection details until Task 14.
  - Snippet editing behaves exactly as before: saving at once, read-only while the file has an error, Insert Variable, the "targets xpnd" skip.
- [ ] **Step 2: Wire it up.** `onActivate`: a connection goes to `service.connect(id, typedInto: pid)`, and a folder to `quickMenu.show(...)`. The quick menu and launcher call `engine.exclusive { await service.connect(...) }`.
- [ ] **Step 3: Verify.** Run the full suite (all snippet tests unchanged and green) and `make app`. Then `make run`, confirm `pgrep -x xpnd`, and `make stop`.
- [ ] **Step 4: Commit.** `feat: make xpnd a Dock app with a connections and snippets window`

### Task 14: Folder and connection editors, and the 1Password picker

**Files:**
- Create: `Sources/xpnd/Main/ConnectionEditorView.swift`, `Sources/xpnd/Main/FolderEditorView.swift`, `Sources/xpnd/Main/CredentialPickerSheet.swift`
- Modify: `Sources/xpnd/Main/Sidebar.swift` (context menus), `Sources/xpnd/Main/DetailsPane.swift`, `Sources/xpnd/Settings/SnippetEditorView.swift` (keyword problems come from `KeywordNamespace`)

**Interfaces:**
- Consumes: `KeywordNamespace.problem`, `ConnectionLibrary.loginCredential/sudoCredential`, `CredentialProvider.search/publicKey`, `ConnectionStore.update`.

- [ ] **Step 1: Build the editors.**
  - **Connection editor:**
    - fields for name, type, host, port (placeholder: the default port), username (placeholder: the resolved credential's username), and activation (with its problem shown inline)
    - credential and sudo credential, each showing "From folder prod: prod-ssh (1Password)", with Choose…, Clear, and Refresh
    - an **Advanced** section (SSH only): a jump host picker (a saved connection or text, refusing password-login jump hosts with a note), SSH options, and Auto-sudo
    - a Connect button
  - **Folder editor:** name, activation (custom, derived with its reason, or none), credential, and sudo credential. The global credentials live in Settings → Password manager (Task 15).
  - **Sidebar context menus:**
    - on a folder: New Connection, New Folder, Rename, Set Activation…, Move to…, Delete (with confirmation if not empty)
    - on a connection: Connect, Duplicate, Move to…, Delete
    - double-clicking a connection connects
  - **Credential picker sheet:** debounced search over `provider.search` and the chosen account. Picking stores `item.ref(account:)`; for an SSH Key item it also fetches `publicKey(for:)` and writes `keys/<item>.pub`. Provider errors show inline.
  - **Every edit saves at once** through `ConnectionStore.update`. Failures show inline, as the snippet editor's do. Cross-file duplicates are flagged in both editors.
- [ ] **Step 2: Verify.** Run the full suite, `make app`, `make run`, and `make stop`.
- [ ] **Step 3: Commit.** `feat(connections): edit folders and connections with 1Password credentials`

### Task 15: Settings: Terminal, Password manager, and Import/Export

**Files:**
- Create: `Sources/xpnd/Settings/TerminalSettingsView.swift`, `Sources/xpnd/Settings/PasswordManagerSettingsView.swift`
- Modify:
  - `Sources/xpnd/Settings/SettingsWindow.swift`: sections become `general`, `terminal`, `passwordManager`, `importExport`.
  - `Sources/xpnd/Settings/ImportExportView.swift`: a Snippets/Connections switch. Connections export selected folders, and importing lists the hosts being added and asks for confirmation before merging; conflicts get skip, replace, or cancel.
  - `Sources/xpnd/App/AppSettings.swift`: `onePasswordPath: String?` and `onePasswordAccount: String?`.

- [ ] **Step 1: Build the sections.**
  - **Terminal:** the editable list of terminal bundle IDs, plus an "Add frontmost-style app…" picker from `/Applications`. A "When no terminal is in front" choice: a preset with new window or tab (tab only where supported), or a custom template with a `{command}` hint and an example.
  - **Password manager:**
    - provider status (`status()`): found or not, signed in, the account picker
    - the "Integrate with 1Password CLI" note, and an `op` path override
    - the global credential and global sudo credential, using the Task 14 picker sheet
    - a disabled "Bitwarden (coming later)" row, so the boundary is visible
- [ ] **Step 2: Verify.** Run the full suite, `make app`, `make run`, and `make stop`.
- [ ] **Step 3: Commit.** `feat(settings): terminal, password manager, and connection import/export`

---

## Stage 4: Docs and hand-off
**Goal**: The docs describe the shipped behavior, and the user has a manual checklist.
**Success Criteria**: README, CHANGELOG, and DEVELOPMENT.md are accurate. `Tests/Manual/test-connections.yaml` exists, and the user has the checklist.
**Tests**: `xcrun swift test` (all), `make app`
**Status**: Not Started

### Task 16: Docs and manual test data

**Files:**
- Create: `Tests/Manual/test-connections.yaml`, containing a dev and prod tree with a localhost SSH entry, a jump-host example, and a VNC entry. It uses no real credentials, only placeholders the user picks.
- Modify: `README.md`, `CHANGELOG.md` (`## 0.2.0 - Unreleased`, `### Added`), `docs/DEVELOPMENT.md` ("How it works" covering the new types; the 1Password CLI integration requirement), `bin/run.sh` (`--test-snippets` also installs the test connections, backing up the existing `connections.yaml` the same way)
- Test: extend `manualTestSnippetsDecode` with `manualTestConnectionsDecode`

- [ ] **Step 1: Write the docs and test data.** The README is user-first and covers activation strings, the quick menu, the launcher hotkey, credential cascade, terminal settings, and the 1Password setup. The privacy section adds that xpnd stores no secrets, copied passwords are concealed and cleared, and `op` is only run when needed.
- [ ] **Step 2: Verify.** Run the full suite and `make app`.
- [ ] **Step 3: Commit.** `docs: describe the connection manager`

When every stage is complete, delete this file in the final commit (per the user's CLAUDE.md).
