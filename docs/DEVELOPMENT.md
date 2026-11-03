# Development

## Build and run

Requires Xcode (the Makefile uses `xcrun swift`).

```sh
./bin/run.sh # build it universal, as releases are, and launch it; --log also streams what it does
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
  restoring every pasteboard type, and sends keys through `KeystrokeSender` (`SyntheticEvent`).
  `ActionRunner` opens apps and runs Shortcuts (`ShortcutsList` lists them). `HUD` flashes failures.
- `SnippetStore` owns the library, loads and atomically saves `snippets.yaml` through `SnippetYAML`,
  watches the file for edits, and keeps an unreadable file untouched (`loadError`). `KeywordValidation`
  keeps keywords unique. `LibraryImport` merges groups, applies skip/replace (`ConflictChoice`), and
  lists `RiskyAction`s for confirmation.
- `PickerPanel` is the search panel opened by the `GlobalShortcut` hotkey (Carbon); `PickerFilter`
  filters it. `AppSettings` keeps preferences in UserDefaults.
- Settings (`SettingsWindowController`): `GeneralSettingsView`, `SnippetsSettingsView` with
  `SnippetEditorView` and `TemplateTextView`, and `ImportExportView`. `ShortcutRecorder` records the
  picker hotkey.
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
