# Development

## Build and run

Requires Xcode (the Makefile uses `xcrun swift`) and CMake (Homebrew's is fine).

`make freerdp` runs `bin/build-freerdp.sh`: it downloads FreeRDP 3.33.0 and OpenSSL 3.5.9, checks their
SHA-256s, and builds both static for arm64 and x86_64 into `vendor/FreeRDP.xcframework` (about 5 minutes
on an M3 Ultra; `vendor/` is untracked). `make build`, `make test` and `make app` run it when the
xcframework is missing or the script changed. The script is the only place with the pins; to bump one,
edit its version, URL and SHA-256 (`--print` lists them) and run `make freerdp`. It clears the
environment and fences Homebrew and MacPorts out of FreeRDP's configure, pins every optional feature
off (JSON, AAD, Kerberos, smart card, Opus and others, so a stray `certificates.json` or a host library
can't change the build), and aborts if the configured cache differs. `make app` copies the FreeRDP and
OpenSSL licences from `vendor/licenses/` into the bundle.

```sh
./bin/run.sh # build it (Apple silicon only) and launch it; --log also streams what it does
./bin/run.sh --test-snippets     # install Tests/Manual/test-snippets.yaml and test-connections.yaml first (backs up yours)
./bin/run.sh --reset-permissions # clear xpnd's Accessibility and Input Monitoring grants first
make run     # build, bundle, sign, and launch build/xpnd.app
make log     # stream the unified log (subsystem com.jessestilwell.xpnd)
make stop
make test    # unit tests
make release-app # the signed, not yet notarized release app in build/release
make release # a notarized DMG and a signed appcast (bin/build-release.sh)
```

The log never holds typed keys or snippet text.

Nothing runs without Input Monitoring and Accessibility access. On first launch a welcome window
guides the user through both and detects when they're on. The bundle is signed with your first Apple
Development / Developer ID identity so the grants survive rebuilds; ad-hoc signing means granting
again after every build.

## How it works

- `PermissionWatcher` follows Input Monitoring and Accessibility (`InputMonitoringPermission`,
  `AccessibilityPermission`); `WelcomeWindowController` shows the guide until both are on, and
  `AppDelegate` runs the tap only while they are.
- `KeyEventTap` listens (without changing anything) to key presses and clicks and hands them to
  `ExpansionEngine` as `KeyInput`. `TypingBuffer` is the rolling buffer, cleared by non-printing keys,
  clicks, and app switches; `Matcher` picks the longest matching keyword in the library, strict or loose.
- `ExpansionEngine` runs one expansion at a time in two phases. `Template` parses the snippet's text
  into `TemplateToken`s. `Evaluator` computes every value first (through an `EvaluationContext`:
  `LiveEvaluationContext` for the clipboard, dates, environment, `#{combo:}` against a library
  snapshot, `ScriptRunner` and `ProcessRunner` for scripts, and the input form), so a failure throws an
  `ExpansionError` before anything on screen changes. It yields `PlayStep`s.
- `Player` plays the steps: it deletes the keyword, pastes text with `PasteboardSnapshot` saving and
  restoring every pasteboard type, and sends keys through `KeystrokeSender` (`SyntheticEvent`). In
  remote-desktop and VM apps (`CGEventKeystrokeSender.remoteDesktopApps`), or everywhere with the
  General setting, text is typed instead: `KeyMap` finds each character's key on the current layout
  and the modifier keys are pressed around it (CLAUDE.md explains why).
  `ActionRunner` opens apps and runs Shortcuts (`ShortcutsList` lists them). `HUD` flashes failures.
- `SnippetStore` owns the library, loads and atomically saves `snippets.yaml` through `SnippetYAML`,
  watches the file for edits, and keeps an unreadable file untouched (`loadError`). `KeywordValidation`
  keeps keywords unique. `LibraryImport` merges groups, applies skip/replace (`ConflictChoice`), and
  lists `RiskyAction`s for confirmation.
- `PickerPanel` is the search panel opened by the `GlobalShortcut` hotkey (Carbon); `PickerFilter`
  filters it. `AppSettings` keeps preferences in UserDefaults.
- Settings (`SettingsWindowController`): `GeneralSettingsView`, `TerminalSettingsView`,
  `PasswordManagerSettingsView`, and `ImportExportView`. `ShortcutRecorder` records the picker and
  launcher hotkeys.
- The main window (`MainWindowController`): `Sidebar` (with a search that filters snippets through
  `PickerFilter` and connections through `ConnectionFilter`) and `DetailsPane`. Snippets are edited
  through `SnippetEditing`, `SnippetGroupDetails`, and `SnippetDetails` (in
  `Settings/SnippetsSettingsView.swift`) with `SnippetEditorView` and `TemplateTextView`; connections
  through `ConnectionEditing` with `ConnectionEditorView` and `FolderEditorView`.
- Connections: `ConnectionStore` owns the library and atomically saves `connections.yaml` through
  `ConnectionYAML` (an unreadable file is left untouched, like snippets). `KeywordNamespace` makes
  snippet keywords and connection and folder activation strings one namespace; `ExpansionEngine`
  matches both and hands a hit to `AppDelegate.activate` as an `ActivationTarget`. A connection goes to
  `ConnectionService`, a folder to `QuickMenuPanel`; `ConnectionLauncherPanel` (its own hotkey) and
  `MainWindowController` call `connectExclusively`, so one action runs at a time.
- `ConnectionService.connect` has `SSHCommandBuilder` build the argument list (jump hosts, key file,
  options, `sudo -i`; `ShellQuote` quotes it), has `LaunchPlanner` choose a `LaunchPlan` (type into a
  front terminal, AppleScript, `open`, a custom template checked by `templateProblem`, or a `vnc://`
  URL), and `LiveLaunchExecutor` runs it. Only then does `OnePasswordProvider` fetch passwords, which go
  to `SecretClipboard` (concealed and transient markers, cleared after 30 s or on quit).
  `OnePasswordProvider` shells out to `op` through `ProcessRunner` (`item list`, `item get`, `account
  list`, `vault list` as an access probe) and keeps nothing. Public keys are written to `keys/` by `ConnectionEditing` (when an
  SSH key item is picked or refreshed) and by `ConnectionService` (when one is missing at connect),
  both through `SSHCommandBuilder.writeKeyFile`. `SSHCommandBuilder` refuses jump-host chains longer
  than `maxJumpHops` (5), because the quoting grows about fourfold per hop.
- The built-in terminal (`Sources/xpnd/Terminal/`, the only app code that imports SwiftTerm):
  `TerminalSessions` owns the `TerminalSession`s, each backed by a `TerminalHost`; `LiveTerminalHost`
  wraps SwiftTerm's `LocalProcessTerminalView` and runs `/usr/bin/ssh` with the argv from
  `SSHCommandBuilder`; its `ClipboardReadGuard` is the view's `terminalDelegate` and denies the remote
  host's clipboard reads (OSC 52, OSC 5522). `BuiltInTerminalSettings` (with `+SwiftTerm` mapping) holds font, colors,
  cursor and scrollback. `MainWindowController` owns `TerminalSessions` and shows `TerminalWorkspace`
  (tab bar, ended bar, shortcuts, `confirmTerminate`) when any exist, with the editor as an overlay card.
  `LaunchPlanner.plan(... preferBuiltIn:)` yields `LaunchPlan.builtInTab` (also the
  `NoTerminalAction.builtIn` choice), which `ConnectionService` hands to its `openTab` closure.
  `ExpansionTargeting` lets snippets expand inside a focused tab, and typed activations there open a new tab.
- Remote desktops (RDP): `Sources/xpndRDP/` is Objective-C on FreeRDP's Mac client, the only code that
  includes FreeRDP headers. `XPRDPSession` owns the FreeRDP context and its client thread, and calls back
  through a delegate on main (certificates, passwords, disconnects); `XPRDPView` subclasses `MRDPView`
  (input mapping, ⌘ as Ctrl or Windows, clipboard polling, drawing); `XPRDPClipboard` is the clipboard
  channel in place of the Mac client's (`XPPreConnect` unsubscribes MRDPView's channel handlers and passes
  them every other channel): text both ways, and Finder files to Windows through FreeRDP's file context
  (`client_cliprdr_file`); `XPRDPClipboardFilter` keeps concealed and secret items from the remote;
  `XPRDPResizeCoalescer` debounces Display Control resizes.
  In `Sources/xpnd/RemoteDesktop/`: `RDPOptions`/`RDPSettings` (per connection and defaults) resolve to an
  `RDPSessionConfig`, `RDPSettingMapping` turns that into FreeRDP setting names, `RDPHost` is the tab's
  `TerminalHost` (`TerminalSession.kind` is `.remoteDesktop`), `RDPErrorText` words `ERRCONNECT_*`/`ERRINFO_*`,
  `RDPReconnectPolicy` decides auto-reconnect, and `RDPPrompts` and `RDPOptionLabels` serve the sheets
  and Settings → Remote Desktop. `ConnectionService` fetches the password before the `.rdpTab` plan opens
  the tab; it goes into the session's memory, never the clipboard or a log. On close xpnd's copies are
  zeroed; FreeRDP frees its own.
  Snippets type as keystrokes in an RDP tab (`focusedSessionKind`).
- `xpnd.entitlements` has `com.apple.security.automation.apple-events` and `Info.plist` has
  `NSAppleEventsUsageDescription`: the hardened release build needs both to send AppleScript to Terminal
  and iTerm2. The 1Password CLI needs "Integrate with 1Password CLI" (Settings → Developer) to answer.
- Tests never run `op` against an account: they inject a fake runner into `OnePasswordProvider` or a fake `CredentialProvider`.
  Keep it that way, because a real call prompts for Touch ID and reads a real vault.
- The app is a Dock app (`LSUIElement` false) with `MainWindowController`; Settings has General,
  Terminal, Remote Desktop, Password Manager, and Import/Export.
- `./bin/run.sh --test-snippets` copies `Tests/Manual/test-snippets.yaml` (with `__MANUAL__` filled in)
  and `Tests/Manual/test-connections.yaml` into Application Support, first backing up any existing
  `snippets.yaml` and `connections.yaml` under a dated name. `manualTestSnippetsDecode` and
  `manualTestConnectionsDecode` keep both files valid.
- `Updates` wraps Sparkle. It stays off (no menu item, no toggle) unless Info.plist has both
  `SUFeedURL` and `SUPublicEDKey`. Debug builds check only when asked.

## Releases and updates

Updates go through [Sparkle](https://sparkle-project.org). The app reads the appcast attached to the
latest GitHub release and installs an update only if it's signed with the key whose public half is
`SUPublicEDKey`.

### One-time setup

1. Generate the update signing key, which stays in the login keychain:
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account xpnd`. Back it up with
   `generate_keys --account xpnd -x <file>`; without it no update can be signed for installed copies.
2. Add to `Resources/Info.plist`: `SUPublicEDKey` (the printed public key) and `SUFeedURL`
   (`https://github.com/jstilwell/xpnd/releases/latest/download/appcast.xml`). `SURequireSignedFeed` and
   `SUVerifyUpdateBeforeExtraction` are already there. Until both keys are set, `Updates.isConfigured`
   keeps updates off.
3. Have a Developer ID Application certificate for team `G65RD22S57` (the Makefile and script refuse any
   other team), notary credentials saved with `xcrun notarytool store-credentials notarytool-profile`,
   the GitHub CLI signed in, and a public repository.

### Each release

1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` and date the
   entry in `CHANGELOG.md` (its bullets become the release notes).
2. Commit, then run `./bin/build-release.sh --upload`.

The script builds a universal app signed with Developer ID and the hardened runtime, puts it in a
signed DMG, notarizes and staples it, signs the update and the appcast, and publishes both as a GitHub
release (a draft first). Without `--upload` it stops before publishing.
