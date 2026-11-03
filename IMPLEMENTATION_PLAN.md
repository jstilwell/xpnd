# xpnd Text Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu bar macOS app that expands typed keywords into Beeftext-style templates (variables, input forms, app/Shortcut actions), with a hotkey picker, a Settings editor, and YAML storage, built and released like HoverEnhance.

**Architecture:** One SwiftPM executable target, `xpnd`, bundled into `build/xpnd.app` by a Makefile copied from HoverEnhance. The pure core is unit-tested with fakes: snippet model, YAML codec, template parser, evaluator, matcher, import merge, and player. That core turns a snippet into a list of `PlayStep`s. The thin AppKit shell around it handles the event tap, `CGEvent` keystrokes, panels, and Settings.

**Tech Stack:** Swift 6.4 (Xcode 27.2, `xcrun swift`), SwiftUI and AppKit, Swift Testing, Sparkle 2.10.1, Yams 6.2.2, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-11-03-text-expansion-design.md` (read it before any task; the plan argues from it). Reference app: `/Users/jesse/code/apps/HoverEnhance`.

## Global Constraints

- Work on branch `feature/text-expansion` (create it from `main` before Task 1). Commit after each task, using Conventional Commits. Never use `--no-verify`.
- macOS 14 minimum (`platforms: [.macOS(.v14)]`, `LSMinimumSystemVersion` 14.0).
- Bundle ID `com.jessestilwell.xpnd`, executable and module named `xpnd`, GitHub repo `jstilwell/xpnd`, release team `G65RD22S57`.
- Dependencies are pinned exactly: `.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")` and `.package(url: "https://github.com/jpsim/Yams", exact: "6.2.2")`. Add no others.
- Non-sandboxed, with no Dock icon (`LSUIElement` true, `.accessory` activation policy).
- **Never log, store, or send typed keystrokes, buffer contents, or expanded text**, not even in debug builds. The only network traffic is Sparkle, and only when update checks are on.
- Snippets file: `~/Library/Application Support/xpnd/snippets.yaml`. Writes are atomic, and the app never overwrites a file it couldn't parse.
- Run commands without a shell. `#{shell:}` executes the script path directly; `shortcuts` gets the name as an argument.
- Variable syntax, escaping, and names are exactly as the spec's Variables table lists them. Names are case-sensitive, and anything unknown or invalid stays as literal text.
- Tests use Swift Testing (`import Testing`, `@testable import xpnd`), as HoverEnhance does.
- README, CHANGELOG, and docs/DEVELOPMENT.md follow HoverEnhance's `CLAUDE.md` conventions. The license is MIT, "Copyright (c) 2026 Stilwe LLC".

## Review Focus

1. **The snippets file is hand-edited into invalid YAML while the app runs.** The app keeps the last good library, shows the error, refuses to save, and leaves the file's bytes untouched. Test: Task 3 `externalInvalidEditKeepsLastGoodLibrary`.
2. **A `#{shell:}` script prints a lot (≥1 MB) or never exits.** There's no pipe deadlock, the timeout kills the script, and typing never freezes. Tests: Task 7 `largeOutputDoesNotDeadlock` and `timeoutKillsScript`.
3. **The clipboard holds an image, files, or custom types when an expansion runs.** Every type and its bytes come back after the paste. Test: Task 9 `snapshotRestoresEveryType`.
4. **The user keeps typing while an expansion is in flight** (form open, slow script). Those keystrokes neither trigger a second expansion nor corrupt the buffer. Test: Task 10 `typingDuringExpansionIsIgnored`.
5. **Non-ASCII keywords and text** (👍🏽, é, CJK). Backspace and left-arrow counts are by `Character`, not UTF-16 unit. Tests: Task 6 `cursorCountsCharacters` and Task 10 `emojiKeywordDeletesByCharacter`.

---

## Stage 1: Foundation
**Goal**: App skeleton that builds and runs, plus the snippet model, YAML, store, and import logic.
**Success Criteria**: `make run` shows a menu bar item with Quit, and `make test` passes for Tasks 2–5.
**Tests**: SnippetYAMLTests, SnippetStoreTests, TemplateTests, LibraryImportTests
**Status**: Not Started

### Task 1: Project scaffold and app shell

**Files:**
- Create: `Package.swift`, `Makefile`, `Resources/Info.plist`, `.gitignore`, `LICENSE`, `bin/run.sh`, `Sources/xpnd/main.swift`, `Sources/xpnd/App/AppDelegate.swift`, `Sources/xpnd/App/Log.swift`

**Interfaces:**
- Produces: `let log: Logger` (subsystem `com.jessestilwell.xpnd`, category `app`). `AppDelegate` owns `statusItem: NSStatusItem` and a `menu: NSMenu`, which later tasks add items to through `func rebuildMenu()`.

- [ ] **Step 1: Copy and adapt the build files from HoverEnhance**
  - `Package.swift`: as HoverEnhance's, but with the two exact pins from Global Constraints and one `executableTarget(name: "xpnd")` that depends on Sparkle and Yams and keeps the rpath linker flag. There's no test target yet; Task 2 adds it.
  - `Makefile`: HoverEnhance's, with `APP_NAME := xpnd` and `BUNDLE_ID := com.jessestilwell.xpnd`. Delete the `--entitlements` flag and its comment, because xpnd needs no entitlements. Delete the "No resources found" guard, so an empty `Resources/` is allowed.
  - `Resources/Info.plist`: HoverEnhance's, with names changed to xpnd and version `0.1.0`/`0.1.0`. Remove the `NSLocation*`, `SUFeedURL`, `SUPublicEDKey` and `CFBundleIconFile` keys; Task 13 adds the update keys back.
  - `.gitignore`: verbatim from HoverEnhance.
  - `bin/run.sh`: HoverEnhance's, with the name changed.
  - `LICENSE`: MIT, "Copyright (c) 2026 Stilwe LLC".
- [ ] **Step 2: Write `main.swift` and `AppDelegate`.** `main.swift` is HoverEnhance's minus the `FileDetails` line. `AppDelegate.applicationDidFinishLaunching` creates the status item, using the SF Symbol `text.cursor` as a template image, with a menu holding only "Quit xpnd" (⌘Q).
- [ ] **Step 3: Verify.** Run `make app && codesign -dv build/xpnd.app 2>&1 | grep Identifier`. Expected: `Identifier=com.jessestilwell.xpnd`. Then run `make run`. Expected: the menu bar shows the icon, and Quit quits.
- [ ] **Step 4: Commit.** Run `git add -A && git commit -m "build: scaffold xpnd app from HoverEnhance build setup"`.

### Task 2: Snippet model and YAML codec

**Files:**
- Modify: `Package.swift` (add `.testTarget(name: "xpndTests", dependencies: ["xpnd"])`)
- Create: `Sources/xpnd/Library/Snippet.swift`, `Sources/xpnd/Library/SnippetYAML.swift`
- Test: `Tests/xpndTests/SnippetYAMLTests.swift`

**Interfaces:**
- Produces:
  - `enum MatchingMode: String, Codable, Sendable { case strict, loose }`
  - `struct Snippet: Identifiable, Hashable, Sendable { var id = UUID(); var name: String; var keyword: String; var matching: MatchingMode = .strict; var enabled = true; var text: String }`
  - `struct SnippetGroup: Identifiable, Hashable, Sendable { var id = UUID(); var name: String; var description = ""; var enabled = true; var snippets: [Snippet] }`
  - `struct SnippetLibrary: Hashable, Sendable`, with:
    - `var groups: [SnippetGroup]`
    - `static let empty`
    - `var activeSnippets: [Snippet]`: enabled snippets in enabled groups
    - `func snippet(keyword: String) -> Snippet?`: any snippet, including disabled ones, so helper snippets used only through `#{combo:}` can stay switched off (my call)
    - `var duplicateKeywords: [String]`: sorted
  - `enum SnippetYAML`, with:
    - `static let currentVersion = 1`
    - `static func decode(_ yaml: String) throws(SnippetYAMLError) -> SnippetLibrary`
    - `static func encode(_ library: SnippetLibrary) -> String`
  - `enum SnippetYAMLError: Error, Equatable { case malformed(String), unsupportedVersion(Int), duplicateKeywords([String]) }`
  - IDs are not written to YAML. They're generated on decode.

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func decodesSpecExample()          // the spec's schema block: 1 group "Work", snippet ";tix", .strict, enabled, text has 3 lines
  @Test func missingOptionalFieldsDefault() // snippet with only name/keyword/text → .strict, enabled true; group description ""
  @Test func roundTripsThroughEncode()      // decode(encode(lib)) equals lib ignoring ids (compare a helper that maps away ids)
  @Test func multilineTextIsLiteralBlock()  // encode of text "a\nb" contains "text: |"
  @Test func malformedYAMLThrows()          // "groups: [" → .malformed
  @Test func futureVersionThrows()          // "version: 2\ngroups: []" → .unsupportedVersion(2)
  @Test func duplicateKeywordsThrow()       // ";a" in two groups → .duplicateKeywords([";a"])
  ```
- [ ] **Step 2: Run the tests to see them fail.** Run `xcrun swift test --filter SnippetYAMLTests`. Expected: a compile failure, because the types don't exist yet.
- [ ] **Step 3: Implement.** Use private `Codable` DTOs with optional fields, decoded with `YAMLDecoder`. Encode with `YAMLEncoder` and `options.newLineScalarStyle = .literal`. If Yams 6.2.2 lacks that option, build a `Node` by hand and set `.literal` style on multi-line scalars.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter SnippetYAMLTests`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `git commit -am "feat(library): add snippet model and YAML codec"` (adding new files first).

### Task 3: Snippet store with atomic saves and file watching

**Files:**
- Create: `Sources/xpnd/Library/SnippetStore.swift`
- Test: `Tests/xpndTests/SnippetStoreTests.swift`

**Interfaces:**
- Consumes: `SnippetLibrary` and `SnippetYAML` (Task 2).
- Produces:
  - `@MainActor @Observable final class SnippetStore`, with:
    - `init(fileURL: URL)`
    - `static var defaultURL: URL`
    - `private(set) var library: SnippetLibrary`
    - `private(set) var loadError: String?`
    - `func load()`
    - `func update(_ change: (inout SnippetLibrary) -> Void) throws(StoreError)`
    - `func startWatching()`
    - `func stopWatching()`
  - `enum StoreError: Error, Equatable { case fileUnreadable, duplicateKeyword(String) }`

- [ ] **Step 1: Write the failing tests** (each in a fresh temporary directory).
  ```swift
  @Test func missingFileLoadsEmptyAndWritesNothing()  // library == .empty, file still absent
  @Test func updateSavesAndReloads()                  // update adds group; new store on same URL loads it
  @Test func saveLeavesNoTempFiles()                  // directory contains only snippets.yaml
  @Test func malformedFileIsNeverOverwritten()        // write "groups: [" ; load → loadError != nil; update throws .fileUnreadable; bytes unchanged
  @Test func duplicateKeywordIsRefused()              // update creating 2nd ";a" throws .duplicateKeyword(";a"); file unchanged
  @Test func externalEditReloads()                    // startWatching; write new valid YAML externally; within 2s library reflects it
  @Test func externalInvalidEditKeepsLastGoodLibrary() // startWatching; write "groups: ["; within 2s loadError != nil, library unchanged, file bytes still the invalid text
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter SnippetStoreTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - A missing file isn't an error; `update` creates the parent directory.
  - `loadError` is set only when parsing fails. Every `update` while `loadError != nil` throws `.fileUnreadable`.
  - Saving writes with `Data.write(to:options: .atomic)`.
  - Watching: atomic renames swap the file's inode, so watch the parent directory with `DispatchSource.makeFileSystemObjectSource(... eventMask: .write)` and reload when the file's contents differ from the last text this store read or wrote. A valid reload clears `loadError`.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter SnippetStoreTests`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `git commit -m "feat(library): add YAML-backed snippet store with file watching"`.

### Task 4: Template parser

**Files:**
- Create: `Sources/xpnd/Expansion/Template.swift`
- Test: `Tests/xpndTests/TemplateTests.swift`

**Interfaces:**
- Produces:
  - `enum TemplateToken: Equatable, Sendable { case text(String); case variable(name: String, argument: String?, raw: String) }`
  - `enum Template { static func parse(_ text: String) -> [TemplateToken] }`

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func plainText()            // "hi" → [.text("hi")]
  @Test func simpleVariable()       // "a#{date}b" → [.text("a"), .variable("date", nil, "#{date}"), .text("b")]
  @Test func argumentKeepsColons()  // "#{dateTime:HH:mm}" → .variable("dateTime", "HH:mm", ...)
  @Test func escapesInArgument()    // #"#{input:a\}b\\c}"# → argument "a}b\\c" (i.e. a}b\c), raw is the original
  @Test func unterminatedIsText()   // "x#{date" → [.text("x#{date")]
  @Test func spaceInBracesIsText()  // "#{ date }" → [.text("#{ date }")]
  @Test func adjacentTextMerges()   // "a#{ x }b" → one .text
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter TemplateTests`. Expected: FAIL.
- [ ] **Step 3: Implement `Template.parse`.**
  - A variable is `#{`, a name of ASCII letters, then optionally `:` and an argument, ending at the first unescaped `}`.
  - `\}` and `\\` are escapes only inside an argument; elsewhere a backslash is literal.
  - Anything else that starts with `#{` is text.
  - The parser accepts any name; the evaluator decides whether it's known.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter TemplateTests`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `git commit -m "feat(expansion): add template parser"`.

### Task 5: Import merge, export, and risky-action detection

**Files:**
- Create: `Sources/xpnd/Library/LibraryImport.swift`
- Test: `Tests/xpndTests/LibraryImportTests.swift`

**Interfaces:**
- Consumes: `Template.parse` (Task 4) and `SnippetYAML` (Task 2).
- Produces:
  - `enum ConflictChoice: Sendable { case skip, replace }`
  - `struct RiskyAction: Hashable, Sendable { enum Kind: Sendable { case shell, openApp, runShortcut }; let snippetName: String; let keyword: String; let kind: Kind; let target: String }`
  - `enum LibraryImport`, with:
    - `static func conflicts(incoming: SnippetLibrary, existing: SnippetLibrary) -> [String]`
    - `static func merge(_ incoming: SnippetLibrary, into existing: SnippetLibrary, choice: ConflictChoice) -> SnippetLibrary`
    - `static func riskyActions(in library: SnippetLibrary) -> [RiskyAction]`
    - `static func export(_ library: SnippetLibrary, groups: Set<SnippetGroup.ID>?) -> String` (`nil` means all groups)

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func sameNamedGroupsMerge()          // existing "Work"[;a] + incoming "Work"[;b] → one "Work" with ;a,;b
  @Test func newGroupIsAdded()
  @Test func skipKeepsExisting()             // conflict ;a → existing text kept, group unchanged
  @Test func replaceMovesToIncomingGroup()   // existing "Home"[;a "old"], incoming "Work"[;a "new"] → Home lacks ;a, Work has ;a "new"
  @Test func conflictsListed()               // == [";a"]
  @Test func riskyActionsFound()             // texts with #{shell:/x.sh:500}, #{openApp:/A.app}, #{runShortcut:Foo} → 3 entries, targets "/x.sh", "/A.app", "Foo"
  @Test func exportSelectedGroupsRoundTrips() // export(lib, groups:[workID]) decodes to just "Work"
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter LibraryImportTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Groups merge by exact name. With `.replace`, the existing snippet is removed wherever it is, and the incoming one is added to its incoming group. A shell target drops a trailing `:<digits>` timeout.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter LibraryImportTests`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `git commit -m "feat(library): add YAML import merge, export, and risky-action detection"`.

---

## Stage 2: Expansion core
**Goal**: The pure pipeline: snippet → evaluated `PlayStep`s → played through a fakeable sender, plus a matcher for typed input.
**Success Criteria**: All the spec's evaluator, matcher, and action tests pass with fakes, without the app running.
**Tests**: EvaluatorTests, ProcessRunnerTests, ActionRunnerTests, TypingTests, PlayerTests
**Status**: Not Started

### Task 6: Evaluator

**Files:**
- Create: `Sources/xpnd/Expansion/PlayStep.swift`, `Sources/xpnd/Expansion/Evaluator.swift`, `Sources/xpnd/Expansion/ExpansionError.swift`
- Test: `Tests/xpndTests/EvaluatorTests.swift`

**Interfaces:**
- Consumes: `Template.parse` and `Snippet`.
- Produces:
  - `enum KeyName: String, CaseIterable, Sendable`, with cases `tab, enter, space, delete, forwardDelete, home, end, pageUp, pageDown, up, down, left, right, escape, f1 … f20` and `var keyCode: CGKeyCode`.
  - `struct KeyCombo: Equatable, Sendable { var command, option, control, shift: Bool; var keyCode: CGKeyCode; static func parse(_ s: String) -> KeyCombo? }`. It parses `Cmd+Shift+J`, accepting one letter, one digit, or a `KeyName` raw value as the final key.
  - `enum PlayStep: Equatable, Sendable { case paste(String); case key(KeyName, count: Int); case shortcut(KeyCombo); case delay(milliseconds: Int); case openApp(path: String); case runShortcut(name: String); case moveLeft(Int) }`
  - `enum ExpansionError: Error, Equatable, Sendable`, with:
    - script cases: `missingCombo(String)`, `scriptNotFound(path: String)`, `scriptFailed(path: String, status: Int32)`, `scriptTimedOut(path: String)`
    - `inputCancelled`
    - action cases: `appNotFound(path: String)`, `unknownShortcut(String)`, `shortcutFailed(name: String, status: Int32)`, `shortcutTimedOut(String)`
    - `var message: String`, a one-line, user-facing message
  - `protocol EvaluationContext: Sendable`, with:
    - `var now: Date { get }`
    - `var locale: Locale { get }`
    - `var timeZone: TimeZone { get }`
    - `func clipboardText() async -> String?`
    - `func environment(_ name: String) -> String?`
    - `func snippet(keyword: String) -> Snippet?`
    - `func runScript(path: String, timeoutMs: Int) async throws(ExpansionError) -> String`
    - `func askInputs(_ labels: [String]) async -> [String: String]?`
  - `enum Evaluator { static func evaluate(_ snippet: Snippet, context: some EvaluationContext) async throws(ExpansionError) -> [PlayStep] }`

- [ ] **Step 1: Write the failing tests.** They use a `FakeContext` with `now` 2026-11-03T14:05:09Z, UTC, `en_US_POSIX`, recorded script calls, and scripted input answers.
  ```swift
  @Test func plainTextIsOnePaste()            // "hi" → [.paste("hi")]
  @Test func clipboardInsertedOrEmpty()       // "[#{clipboard}]" → "[x]"; nil clipboard → "[]"
  @Test func customDateFormats()              // "#{dateTime:yyyy-MM-dd}" → "2026-11-03"; "#{dateTime:HH:mm}" → "14:05"
  @Test func dateShift()                      // "#{dateTime:+1d-2h:yyyy-MM-dd HH}" → "2026-11-04 12"; "#{dateTime:+1w:yyyy-MM-dd}" → "2026-11-10"
  @Test func shiftWithEmptyFormatUsesShortStyles() // "#{dateTime:+1M:}" == DateFormatter(short,short) of 2026-12-03T14:05:09Z
  @Test func comboNestsAndCases()             // ";n" text "Bob"; "#{combo:;n} #{upper:;n} #{lower:;n}" → "Bob BOB bob"
  @Test func missingComboThrows()             // → .missingCombo(";zz")
  @Test func comboCycleLeftLiteral()          // a="x#{combo:b}", b="y#{combo:a}" → evaluate a == "xy#{combo:a}"
  @Test func inputsAskedOnceInOrder()         // "#{input:Name} #{input:Ticket #} #{input:Name}" + nested combo with #{input:Team} → asked ["Name","Ticket #","Team"]; values substituted
  @Test func cancelledInputThrows()           // askInputs returns nil → .inputCancelled
  @Test func cursorMovesLeft()                // "ab#{cursor}cd#{cursor}" → [.paste("abcd"), .moveLeft(2)]
  @Test func cursorCountsCharacters()         // "a#{cursor}👍🏽é" → [.paste("a👍🏽é"), .moveLeft(2)]
  @Test func cursorIgnoredWhenStepsFollow()   // "a#{cursor}b#{key:tab}" → no .moveLeft
  @Test func keysShortcutsDelaysActions()     // "a#{key:tab:3}b#{shortcut:Cmd+Shift+J}#{delay:500}#{openApp:/X.app}#{runShortcut:Foo}c"
                                              //  → [.paste("a"), .key(.tab,3), .paste("b"), .shortcut(cmd+shift J), .delay(500), .openApp("/X.app"), .runShortcut("Foo"), .paste("c")]
  @Test func unknownOrInvalidLeftLiteral()    // "#{nope} #{key:bogus} #{delay:-5} #{dateTime:+1x:}" pasted verbatim
  @Test func envVar()                         // set "HOME" in fake → value; missing → ""
  @Test func shellTimeoutsAndTrim()           // "#{shell:/s.sh:2500}" → call ("/s.sh",2500); "#{shell:/s.sh}" → 10000; output "out\n" → "out"; fake throw propagates
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter EvaluatorTests`. Expected: FAIL.
- [ ] **Step 3: Implement `Evaluator.evaluate` in two passes.**
  - **Pass 1** collects `#{input:}` labels in order of first appearance, walking `#{combo:}`/`#{upper:}`/`#{lower:}` with a keyword stack as a cycle guard. If there are any, it calls `askInputs` once, and `nil` throws `.inputCancelled`.
  - **Pass 2** emits steps:
    - **Merging:** adjacent pastes merge, and empty pastes are dropped.
    - **Combos:** upper and lower apply only to the nested result's `.paste` text. A keyword already on the stack emits its raw text.
    - **Dates:** `date`/`time`/`dateTime` use `DateFormatter` with `.short` styles (date only, time only, or both). For a `dateTime` argument, if the part before the first `:` matches `^([+-]\d+[yMwdhms])+$`, it's a shift (Gregorian calendar in `timeZone`) and the rest is the format, where empty means the short styles. Otherwise the whole argument is a format.
    - **Shell:** for `shell`, if the last `:` component is all digits, it's the timeout; otherwise the timeout is 10000.
    - **Key counts:** `key` counts must be ≥1, and `delay` must be ≥0. Anything invalid stays literal.
    - **Cursor:** the first `#{cursor}` records a position. If only `.paste` steps follow it, append `.moveLeft(characters after it)`. Otherwise drop it (shortcut: the cursor is honoured only when nothing but text follows it; upgrade if users need cursors before keys). Write that shortcut comment in the code.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter EvaluatorTests`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `git commit -m "feat(expansion): evaluate templates into play steps"`.

### Task 7: Process runner, scripts, and actions

**Files:**
- Create: `Sources/xpnd/Expansion/ProcessRunner.swift`, `Sources/xpnd/Expansion/ActionRunner.swift`, `Sources/xpnd/Expansion/ShortcutsList.swift`
- Test: `Tests/xpndTests/ProcessRunnerTests.swift`, `Tests/xpndTests/ActionRunnerTests.swift`

**Interfaces:**
- Consumes: `ExpansionError` (Task 6).
- Produces:
  - `enum ProcessRunner`, with `static func run(_ executable: URL, arguments: [String], timeoutMs: Int) async throws(ProcessRunError) -> (status: Int32, stdout: String)`. A `timeoutMs` of 0 means none.
  - `enum ProcessRunError: Error, Equatable { case notExecutable, timedOut }`
  - `enum ScriptRunner { static func run(path: String, timeoutMs: Int) async throws(ExpansionError) -> String }`. It maps errors onto `scriptNotFound`, `scriptFailed`, and `scriptTimedOut`, and trims one trailing newline.
  - `protocol ActionRunning: Sendable`, with:
    - `func openApp(path: String) async throws(ExpansionError)`
    - `func runShortcut(name: String) async throws(ExpansionError)`
  - `struct ActionRunner: ActionRunning`, with `init(launch: @Sendable (URL) async throws -> Void = NSWorkspace default, shortcutNames: @Sendable () async -> [String] = ShortcutsList.fetch)`
  - `enum ShortcutsList`, with:
    - `static func parse(_ output: String) -> [String]`
    - `static func fetch() async -> [String]` (`/usr/bin/shortcuts list`)

- [ ] **Step 1: Write the failing tests.** Temporary scripts are written with `#!/bin/sh` and `chmod 755`.
  ```swift
  @Test func scriptOutput()               // echo hi → "hi"
  @Test func nonZeroExitIsFailure()       // exit 3 → .scriptFailed(path, 3)
  @Test func timeoutKillsScript()         // sleep 30, timeout 200 → .scriptTimedOut within 2s
  @Test func largeOutputDoesNotDeadlock() // head -c 1000000 /dev/zero | tr '\0' a → 1_000_000 chars
  @Test func nonExecutableIsNotFound()    // file without +x, and a missing path → .scriptNotFound
  @Test func missingAppPathErrors()       // openApp("/Applications/Nope-\(UUID()).app") → .appNotFound, launch never called
  @Test func existingAppLaunches()        // openApp("/System/Applications/Calculator.app") → fake launch got that URL
  @Test func unknownShortcutErrors()      // shortcutNames ["A"]; runShortcut("B") → .unknownShortcut("B")
  @Test func shortcutsListParses()        // "A\n B \n\n" → ["A","B"]
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter "ProcessRunnerTests|ActionRunnerTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `Process`, with stdout read concurrently (a `readabilityHandler` that appends to a locked buffer), so a full pipe can't block.
  - On timeout, send `terminate()` and then `SIGKILL` after 1 s.
  - Check `isExecutableFile(atPath:)` before launching.
  - `openApp` requires an existing directory ending in `.app`.
  - `runShortcut` checks the name against `shortcutNames()`, then runs `/usr/bin/shortcuts run <name>` with a 30000 ms timeout.
- [ ] **Step 4: Run the tests to see them pass.** Run the same filter. Expected: PASS.
- [ ] **Step 5: Commit.** Run `git commit -m "feat(expansion): run scripts, apps, and Shortcuts without a shell"`.

### Task 8: Typing buffer and matcher

**Files:**
- Create: `Sources/xpnd/Expansion/Typing.swift`
- Test: `Tests/xpndTests/TypingTests.swift`

**Interfaces:**
- Produces:
  - `enum KeyInput: Equatable, Sendable { case characters(String), backspace, reset, ignore }`, with `static func classify(keyCode: UInt16, characters: String, flags: CGEventFlags) -> KeyInput`
  - `struct TypingBuffer { static let capacity = 128; private(set) var text = ""; mutating func apply(_ input: KeyInput) }`
  - `enum Matcher { static func match(_ buffer: String, in snippets: [Snippet]) -> Snippet? }`

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func strictNeedsExactBuffer()   // ";sig" matches strict ";sig"; "x;sig" does not
  @Test func looseMatchesSuffix()       // "First==>" matches loose "==>"
  @Test func longestKeywordWins()       // loose "sig" + strict ";sig", buffer ";sig" → ";sig"
  @Test func backspaceRemovesLast()
  @Test func resetKeysClear()           // keyCodes 36,48,49,53,123,124,125,126,117,115,119,116,121,76 → .reset
  @Test func commandOrControlResets()   // "c" with .maskCommand → .reset
  @Test func optionCharacterAppends()   // "é" with .maskAlternate → .characters("é")
  @Test func deadKeyIgnored()           // characters "" → .ignore
  @Test func controlCharactersReset()   // "\u{7}" → .reset
  @Test func capacityKeepsTail()        // 200 chars → text.count == 128, ends with last typed
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter TypingTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Key code 51 is backspace. The reset key codes are the list in the test, plus F-keys. Check flags before characters.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter TypingTests`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `git commit -m "feat(expansion): add typing buffer and keyword matcher"`.

### Task 9: Player, pasteboard snapshot, and keystroke sender

**Files:**
- Create: `Sources/xpnd/Expansion/Player.swift`, `Sources/xpnd/Expansion/PasteboardSnapshot.swift`, `Sources/xpnd/Expansion/KeystrokeSender.swift`
- Test: `Tests/xpndTests/PlayerTests.swift`

**Interfaces:**
- Consumes: `PlayStep`, `KeyName`, `KeyCombo` (Task 6) and `ActionRunning` (Task 7).
- Produces:
  - `@MainActor protocol KeystrokeSending`, with:
    - `func backspace(times: Int) async`
    - `func paste(_ text: String) async`
    - `func press(_ key: KeyName, times: Int) async`
    - `func press(_ combo: KeyCombo) async`
  - `struct PasteboardSnapshot`, with:
    - `static func capture(_ pasteboard: NSPasteboard) -> PasteboardSnapshot`
    - `func restore(to pasteboard: NSPasteboard)`
  - `@MainActor final class CGEventKeystrokeSender: KeystrokeSending`
  - `enum SyntheticEvent { static let marker: Int64 = 0x78706E64 }`: the value set in `.eventSourceUserData` on every event xpnd posts
  - `@MainActor struct Player`, with:
    - `let sender: any KeystrokeSending`
    - `let actions: any ActionRunning`
    - `func play(_ steps: [PlayStep], deletingCharacters: Int) async throws(ExpansionError)`

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func backspacesThenStepsInOrder()   // fake sender log == ["bs 4","paste a","key tab x3","combo","paste b","key left x1"] for steps incl .moveLeft(1)
  @Test func actionFailureStopsPlayback()   // fake actions throws .appNotFound on openApp; later .paste not sent; error rethrown
  @Test func snapshotRestoresEveryType()    // NSPasteboard(name: .init("xpnd-test-\(UUID())")): string + PNG bytes + "com.example.custom" data
                                             // capture → clear & write "other" → restore → all three types present with identical bytes
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter PlayerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - **Player:** backspaces first, then each step. `.delay` maps to `Task.sleep`, and `.moveLeft(n)` to `press(.left, n)`.
  - **Snapshot:** copy every item's every type's data.
  - **`CGEventKeystrokeSender` keystrokes:** post through `CGEventSource(stateID: .privateState)` with the marker set.
  - **`CGEventKeystrokeSender` paste:**
    1. Snapshot the general pasteboard.
    2. Write the text plus the marker types `org.nspasteboard.TransientType` and `org.nspasteboard.AutoGeneratedType`, so clipboard managers skip it.
    3. Post Cmd+V (key code 9).
    4. Wait about 150 ms, then restore the snapshot. Tuning that wait is left to the builder.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter PlayerTests`. Expected: PASS.
- [ ] **Step 5: Commit.** Run `git commit -m "feat(expansion): play steps with pasteboard save and restore"`.

---

## Stage 3: Live app
**Goal**: Typing keywords in real apps expands them, with input forms, error messages, permission onboarding, and the picker.
**Success Criteria**: Every item in Task 10's manual checklist passes in TextEdit and Safari, and the picker hotkey inserts a snippet.
**Tests**: ExpansionEngineTests, PickerFilterTests, plus the manual checklist
**Status**: Not Started

### Task 10: Event tap, engine, input form, permissions, and messages

**Files:**
- Create:
  - `Sources/xpnd/Expansion/ExpansionEngine.swift`
  - `Sources/xpnd/Expansion/KeyEventTap.swift`
  - `Sources/xpnd/Expansion/LiveEvaluationContext.swift`
  - `Sources/xpnd/App/InputForm.swift`
  - `Sources/xpnd/App/AccessibilityPermission.swift` (copied and adapted)
  - `Sources/xpnd/App/WelcomeWindow.swift` (copied and adapted)
  - `Sources/xpnd/App/HUD.swift` (copied)
  - `Sources/xpnd/App/AppSettings.swift`
- Modify: `Sources/xpnd/App/AppDelegate.swift`
- Test: `Tests/xpndTests/ExpansionEngineTests.swift`

**Interfaces:**
- Consumes: Tasks 3 and 6–9.
- Produces:
  - `@MainActor final class ExpansionEngine`, with:
    - `init(store: SnippetStore, player: Player, makeContext: @escaping @MainActor () -> any EvaluationContext, notify: @escaping @MainActor (String) -> Void)`
    - `var isEnabled: Bool`
    - `private(set) var isExpanding: Bool`
    - `func handle(_ input: KeyInput)`
    - `func resetBuffer()`
    - `func expand(_ snippet: Snippet, deletingCharacters: Int) async`
  - `final class KeyEventTap`, with:
    - `init(onKey: @escaping (KeyInput) -> Void, onMouseDown: @escaping () -> Void)`
    - `func start() -> Bool`
    - `func stop()`
  - `@MainActor enum InputForm { static func ask(_ labels: [String]) async -> [String: String]? }`
  - `@MainActor @Observable final class AppSettings`, with:
    - `static let shared`
    - `var expansionEnabled: Bool` (UserDefaults `expansionEnabled`, default true)
  - `HUD.flash(_ text: String, seconds: Double = 3)`, added to the copied HUD

- [ ] **Step 1: Write the failing tests.** They use a fake sender and a fake context with `askInputs` that can suspend on a continuation.
  ```swift
  @Test func matchTriggersExpansion()          // feed ";", "s","i","g" → sender log ["bs 4","paste Best"]
  @Test func failedEvaluationLeavesKeyword()   // text "#{combo:;zz}" → no "bs", notify got ExpansionError.missingCombo(";zz").message
  @Test func typingDuringExpansionIsIgnored()  // while askInputs suspended, feed ";sig" again → after resuming, exactly one "bs" in log; buffer empty
  @Test func disabledOrLoadErrorDoesNothing()  // isEnabled false → no log; store with loadError → no log
  @Test func emojiKeywordDeletesByCharacter()  // keyword "👍🏽!" → "bs 2"
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter ExpansionEngineTests`. Expected: FAIL.
- [ ] **Step 3: Implement `ExpansionEngine`.**
  - `handle` ignores input while disabled, while expanding, or while `store.loadError != nil`.
  - Otherwise it applies the input to the buffer and matches against `activeSnippets`.
  - On a match, it clears the buffer and runs `expand(snippet, deletingCharacters: snippet.keyword.count)`.
  - `expand` sets `isExpanding` and evaluates. On error it calls notify and returns without deleting the keyword. Otherwise it plays, notifies on a play error, and finally clears `isExpanding`.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter ExpansionEngineTests`. Expected: PASS.
- [ ] **Step 5: Implement the live pieces.**
  - **`KeyEventTap`:**
    - `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly)`, for keyDown and left/right/other mouseDown
    - re-enable on `.tapDisabledByTimeout`/`.tapDisabledByUserInput`
    - skip events whose `.eventSourceUserData == SyntheticEvent.marker`
    - skip everything while `IsSecureEventInputEnabled()`
    - get characters from `keyboardGetUnicodeString`
  - **`LiveEvaluationContext`:** `NSPasteboard.general`, `Date()`, `.current` locale and time zone, `ProcessInfo` environment, `store.library.snippet(keyword:)`, `ScriptRunner.run`, `InputForm.ask`.
  - **`InputForm`:**
    - remember `NSWorkspace.shared.frontmostApplication`
    - show a floating titled `NSPanel`, placed near the frontmost window, hosting a SwiftUI form: one `TextField` per label, the first one focused
    - Return submits; Esc and closing cancel
    - afterwards, activate the remembered app and wait (up to 1 s) until it's frontmost before returning
  - **Permissions:** copy `AccessibilityPermission.swift`. Add Input Monitoring (`CGPreflightListenEventAccess`/`CGRequestListenEventAccess`) to the watcher and the welcome window, so both are shown as steps.
  - **AppDelegate:**
    - load the store and `startWatching()`
    - show the welcome window until both permissions are granted, then start the tap
    - reset the buffer on `NSWorkspace.didActivateApplicationNotification` and on mouse-down
    - add the menu items "Expansion On" (checkmark toggling `AppSettings.expansionEnabled`) and, when `loadError != nil`, a disabled "Snippets file has an error" item
    - flash `loadError` at launch
- [ ] **Step 6: Run the manual checklist** (`make run`, TextEdit and Safari).
  1. Hand-write `snippets.yaml` with:
     - the spec's `;tix` example
     - a loose `==>` snippet
     - `;calc` = `#{openApp:/System/Applications/Calculator.app}`
     - `;sh` = `#{shell:<temp script>}`
     - `;sc` = `#{runShortcut:<an existing Shortcut>}`
  2. `;tix` shows one form with two fields. Submitting inserts the text with the cursor at the end. Escape leaves `;tix` in place.
  3. The clipboard (copy an image first) is unchanged after an expansion.
  4. `;calc` opens Calculator and removes `;calc`. A bad app path shows a HUD message.
  5. Nothing expands in a Safari password field.
  6. Edit the YAML externally: the change takes effect without a restart. Break the YAML: a HUD message appears and expansion stops until the file is fixed.
- [ ] **Step 7: Commit.** Run `git commit -m "feat: expand keywords system-wide with input forms and permission onboarding"`.

### Task 11: Picker

**Files:**
- Create: `Sources/xpnd/Picker/PickerFilter.swift`, `Sources/xpnd/Picker/PickerPanel.swift`, `Sources/xpnd/App/GlobalShortcut.swift` (copied verbatim from HoverEnhance)
- Modify: `Sources/xpnd/App/AppSettings.swift`, `Sources/xpnd/App/AppDelegate.swift`
- Test: `Tests/xpndTests/PickerFilterTests.swift`

**Interfaces:**
- Consumes: `ExpansionEngine.expand` (Task 10), and `Shortcut` and `GlobalShortcut` (copied).
- Produces:
  - `enum PickerFilter { static func filter(_ snippets: [Snippet], query: String) -> [Snippet] }`
  - `AppSettings.pickerShortcut: Shortcut?`: stored as JSON under `pickerShortcut`; defaults to Ctrl+Option+Cmd+Space (key code 49)
  - `@MainActor final class PickerPanel`, with `init(store: SnippetStore, engine: ExpansionEngine)` and `func toggle()`

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func emptyQueryListsActiveByName()
  @Test func keywordPrefixRanksFirst()      // snippets: keyword "sig" (name "Zed"), keyword "x" (name "Design"); query "sig" → ["Zed", "Design"] by name
  @Test func caseAndDiacriticInsensitive()  // "cafe" finds name "Café"
  @Test func searchesText()                 // query in text only → included, ranked after name hits
  @Test func disabledExcluded()
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter PickerFilterTests`. Expected: FAIL.
- [ ] **Step 3: Implement `PickerFilter`.** Rank 0 is a keyword with the query as prefix, rank 1 a keyword or name containing it, and rank 2 text containing it. Ties sort by name, using `localizedStandardCompare`.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter PickerFilterTests`. Expected: PASS.
- [ ] **Step 5: Implement `PickerPanel`.**
  - A centered key-capable `NSPanel` (`.nonactivatingPanel`, `canBecomeKey`) hosting a SwiftUI search field and list.
  - Arrow keys move the highlight and Esc closes the panel.
  - Enter closes it, re-activates the previously frontmost app, and calls `engine.expand(snippet, deletingCharacters: 0)`.
  - Register `pickerShortcut` through `GlobalShortcut`. If registration fails, flash "Picker shortcut is in use by another app".
  - Add "Open Picker" to the menu.
- [ ] **Step 6: Verify.** With `make run`, the hotkey opens the picker over TextEdit, typing filters the list, and Enter inserts the snippet (prompts included) into TextEdit.
- [ ] **Step 7: Commit.** Run `git commit -m "feat(picker): search and insert snippets from a hotkey panel"`.

---

## Stage 4: Settings
**Goal**: Edit snippets and groups, change preferences, and import or export YAML, all without touching the file.
**Success Criteria**: Every Settings flow in Task 12's checklist works, and edits show up in `snippets.yaml` at once.
**Tests**: KeywordValidationTests, plus the manual checklist
**Status**: Not Started

### Task 12: Settings window

**Files:**
- Create:
  - `Sources/xpnd/Settings/SettingsWindow.swift` (adapted from HoverEnhance's `SettingsWindowController`)
  - `Sources/xpnd/Settings/GeneralSettingsView.swift`
  - `Sources/xpnd/Settings/SnippetsSettingsView.swift`
  - `Sources/xpnd/Settings/SnippetEditorView.swift`
  - `Sources/xpnd/Settings/TemplateTextView.swift`
  - `Sources/xpnd/Settings/ImportExportView.swift`
  - `Sources/xpnd/Settings/ShortcutRecorder.swift` (copied from HoverEnhance's `SettingsViews.swift:180`)
  - `Sources/xpnd/Library/KeywordValidation.swift`
- Modify: `Sources/xpnd/App/AppDelegate.swift`
- Test: `Tests/xpndTests/KeywordValidationTests.swift`

**Interfaces:**
- Consumes: `SnippetStore.update`, `LibraryImport`, `ShortcutsList.fetch`, `AppSettings`, and `TypingBuffer.capacity`.
- Produces:
  - `extension SnippetLibrary { func keywordProblem(_ keyword: String, for snippet: Snippet.ID?) -> String? }`
  - `enum SettingsSection: CaseIterable { case general, snippets, importExport }`: an enum so projects 2–3 can add sections

- [ ] **Step 1: Write the failing tests.**
  ```swift
  @Test func emptyKeyword()        // "" → "Keyword can't be empty"
  @Test func keywordWithSpace()    // ";a b" → "Keywords can't contain spaces or tabs"   (space resets the buffer, so it could never match)
  @Test func duplicateNamesOwner() // ";sig" owned by "Signature" → "“;sig” is already used by “Signature”"
  @Test func sameSnippetIsFine()   // own id → nil
  @Test func tooLong()             // 129 chars → "Keywords can be at most 128 characters"
  ```
- [ ] **Step 2: Run them to see them fail.** Run `xcrun swift test --filter KeywordValidationTests`. Expected: FAIL.
- [ ] **Step 3: Implement `keywordProblem`.** Use the exact messages above.
- [ ] **Step 4: Run the tests to see them pass.** Run `xcrun swift test --filter KeywordValidationTests`. Expected: PASS.
- [ ] **Step 5: Build the views.**
  - **General:**
    - Expansion on/off (`AppSettings.expansionEnabled`)
    - Launch at login, following HoverEnhance's `SMAppService.mainApp` toggle at `SettingsViews.swift:282-301`
    - Picker shortcut, via `ShortcutRecorder`
  - **Snippets** (a `NavigationSplitView`):
    - Sidebar: groups, with add, rename, delete (confirm when the group isn't empty), enabled toggle, and description.
    - List: snippets, with search and add/delete.
    - Editor:
      - name, keyword (with the inline `keywordProblem`; while there's a problem the change isn't saved), matching picker, enabled toggle
      - template text in `TemplateTextView`, an `NSTextView` wrapper, so variables can be inserted at the caret (SwiftUI's `TextEditor` can't expose the selection on macOS 14)
      - an "Insert Variable" menu with every variable in the spec's table, inserted as a template such as `#{dateTime:yyyy-MM-dd}`
      - "Open App…" (an `NSOpenPanel` with `allowedContentTypes [.application]`, starting in `/Applications`) and "Run Shortcut…" (a sheet listing `ShortcutsList.fetch()`)
    - Every edit goes through `store.update` immediately.
    - Help text: "Saved to ~/Library/Application Support/xpnd/snippets.yaml. Saving from xpnd rewrites the file and drops comments."
  - **Import/Export:**
    - Export: group checkboxes (all on by default), then an `NSSavePanel` (`.yaml`) and `LibraryImport.export`.
    - Import:
      1. An `NSOpenPanel` and `SnippetYAML.decode`, showing any error.
      2. If `riskyActions` isn't empty, a sheet titled "These snippets can run things on this Mac", listing name, keyword, kind, and target, with Cancel and Import.
      3. If `conflicts` isn't empty, an alert ("N keywords already exist") with Skip, Replace, and Cancel.
      4. `store.update { $0 = LibraryImport.merge(...) }`.
  - **Wiring:** add "Settings…" (⌘,) to the menu.
- [ ] **Step 6: Run the manual checklist.**
  - A new snippet appears in `snippets.yaml` at once.
  - A duplicate keyword shows the message and isn't saved.
  - Insert Variable lands at the caret.
  - Open App… inserts `#{openApp:/Applications/…app}`.
  - Export two groups, delete one, and re-import: it comes back.
  - Importing a file with `#{shell:}` shows the confirmation, and Cancel imports nothing.
- [ ] **Step 7: Commit.** Run `git commit -m "feat(settings): edit snippets and groups, import and export YAML"`.

---

## Stage 5: Release
**Goal**: Sparkle updates, a release script, and project docs, so 0.1.0 can be shipped like HoverEnhance.
**Success Criteria**: `make release-app` produces a universal app signed by team G65RD22S57, and the README, CHANGELOG, and DEVELOPMENT.md are accurate.
**Tests**: `xcrun swift test` (all), `make release-app`, and `codesign` checks
**Status**: Not Started

### Task 13: Updates, release script, and docs

**Files:**
- Create: `Sources/xpnd/App/Updates.swift` (copied from HoverEnhance), `bin/build-release.sh` (copied), `README.md`, `CHANGELOG.md`, `docs/DEVELOPMENT.md`
- Modify: `Resources/Info.plist`, `Sources/xpnd/App/AppDelegate.swift`, `Sources/xpnd/Settings/GeneralSettingsView.swift`

**Interfaces:**
- Consumes: `Updates.shared` (`start()`, `checksAutomatically`, `checkForUpdates()`, `isAvailable`), as it is in HoverEnhance.

- [ ] **Step 1: Generate the update signing key (the user does this; the private key never leaves the keychain).** Run `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account xpnd`. Put the printed public key in `Info.plist` as `SUPublicEDKey`. Add `SUFeedURL` `https://github.com/jstilwell/xpnd/releases/latest/download/appcast.xml`, `SURequireSignedFeed` true, and `SUVerifyUpdateBeforeExtraction` true.
- [ ] **Step 2: Wire up Sparkle.** Copy `Updates.swift`. Call `Updates.shared.start()` at launch. Add "Check for Updates…" to the menu when `isAvailable`, and a "Check for updates automatically" toggle to General.
- [ ] **Step 3: Copy `bin/build-release.sh`.** Set `APP_NAME="xpnd"`, `REPO="jstilwell/xpnd"`, and `SPARKLE_ACCOUNT="xpnd"`; everything else stays the same.
- [ ] **Step 4: Write the docs.**
  - **README.md:** HoverEnhance's structure: a centered header, what it does, install, variables, YAML format, and privacy (keystrokes are never stored; the only network use is the optional update check).
  - **CHANGELOG.md:** `## 0.1.0 - Unreleased`, with `### Added` bullets that a user would notice.
  - **docs/DEVELOPMENT.md:** build, run, test, log, release, and a "How it works" section naming the pipeline types from Tasks 6–10.
- [ ] **Step 5: Verify.** Run `xcrun swift test`. Expected: all PASS. Then run `make release-app`. Expected: it ends with `codesign --verify` OK and `TeamIdentifier=G65RD22S57`. Notarizing and `--upload` stay with the user.
- [ ] **Step 6: Commit.** Run `git commit -m "feat: add Sparkle updates, release script, and docs"`.

When all stages are complete, delete this file in the final commit, per the user's CLAUDE.md.
