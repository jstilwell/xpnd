# Expansion Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Batch 1 of the review design: strict keywords on a word boundary, kept keys, one clipboard capture per
expansion with restore-after-read, combo limits, clearer Shortcuts/script errors, cheaper per-key and picker work.

**Architecture:** Space becomes a `KeyInput.boundary`; `Matcher` splits into an instant (loose) match and a
boundary (strict) match that the engine checks *before* applying the key. The engine collects keys typed during an
expansion and hands `Player` a tail closure, read just before the backspaces. `Player` owns the clipboard session
through a new `KeystrokeSending.restoreClipboard()`.

**Tech Stack:** Swift 6, SwiftPM, AppKit, Swift Testing (`make test`).

**Spec:** `docs/superpowers/specs/2026-11-20-review-fixes-design.md` (Batch 1).

## Global Constraints

- Never log, store or put in a fixture keystrokes, the typing buffer, kept keys, or snippet text.
- Boundary characters: space, or a single `Character` with `isPunctuation || isSymbol`. Return and Tab only reset.
- Opening characters that may start a word: `( [ { < " ' `` ` ``.
- Kept keys cap: 64 characters. Combo limits: depth 16, 10,000 steps.
- Paste wait: floor 150 ms after ⌘V, restore 50 ms after the app reads, cap 1 s.
- One commit per task, Conventional Commits, on `fix/expansion-reliability`. CHANGELOG bullets under `## 0.5.0 - Unreleased`.
- Swift files are written with the Write/Edit tools, not shell heredocs.

## Review Focus

1. A keyword whose last character is punctuation (`;sig.`) and a shorter one (`;sig`): typing `;sig.` must fire `;sig.` on the next boundary, not `;sig` on the `.` — test in Task 1.
2. `#{cursor}` snippets with a boundary: caret must stay at the cursor (`moveLeft` grows by the tail) — test in Task 2.
3. A snippet ending in `#{key:enter}`: the space must not be retyped after Enter — test in Task 2.
4. An expansion that throws mid-playback (missing app) must still restore the clipboard — test in Task 3.
5. An app that never reads the pasteboard: restore happens at the 1 s cap, not never — test in Task 3.

---

### Task 1: Boundary input and the two matchers

**Files:**
- Modify: `Sources/xpnd/Expansion/Typing.swift`
- Test: `Tests/xpndTests/TypingTests.swift`

**Interfaces:**
- Produces: `KeyInput.boundary(String)`; `Matcher.instant(_ buffer: String, in: [Snippet]) -> Snippet?` (loose only,
  suffix, longest wins); `Matcher.strict(word: String, boundary: Character, in: [Snippet]) -> Snippet?`;
  `Matcher.isBoundary(_ c: Character) -> Bool`. `Matcher.match` is removed.

- [ ] **Step 1: Write failing tests** in `TypingTests`:
  - `classify(keyCode: 49 /*space*/, characters: " ", flags: [])` == `.boundary(" ")`; with `.maskCommand` == `.reset`.
  - `TypingBuffer` applying `.boundary(" ")` empties `text`.
  - `Matcher.instant(";sig", in: [strict ";sig"])` == nil; `instant("First==>", in: [loose "==>"])?.keyword == "==>"`.
  - `strict(word: ";sig", boundary: " ", in: [strict ";sig"])?.keyword == ";sig"`; boundary `"."` also matches; boundary `"a"` nil.
  - `strict(word: "x;sig", boundary: " ", …)` nil; `strict(word: "(;sig", …)` and `strict(word: "\"(;sig", …)` match.
  - `strict(word: "don't", boundary: " ", in: [strict "t"])` nil (letters before the opening char).
  - With strict `;sig` and `;sig.`: `strict(word: ";sig", boundary: ".", …)` nil; `strict(word: ";sig.", boundary: " ", …)?.keyword == ";sig."`.
  - A loose snippet is never returned by `strict`.
- [ ] **Step 2: Run** `swift test --filter TypingTests` — expect compile failure / FAIL.
- [ ] **Step 3: Implement.** Remove `kVK_Space` from `resetKeyCodes`; space with no ⌘/⌃ classifies as `.boundary(" ")`
  (check before the reset set). `TypingBuffer.apply(.boundary)` resets. `strict`: candidates are strict snippets whose
  keyword equals `word`, or `word.hasSuffix(keyword)` where the characters before it are non-empty and all opening
  characters; drop a candidate if any strict keyword `hasPrefix(candidate.keyword + String(boundary))`; longest wins;
  nil unless `isBoundary(boundary)`. Update the existing `Matcher.match` tests to the new names.
- [ ] **Step 4: Run** `swift test --filter TypingTests` — PASS.
- [ ] **Step 5: Commit** `feat(expansion): match strict keywords on a word boundary` (engine wiring follows in Task 2; the build must compile, so Task 1 and 2 may land as one commit if `ExpansionEngine` won't build without `Matcher.match`).

### Task 2: Engine fires strict snippets on a boundary and keeps typed keys

**Files:**
- Modify: `Sources/xpnd/Expansion/ExpansionEngine.swift`, `Sources/xpnd/Expansion/Player.swift`,
  `Sources/xpnd/Expansion/PlayStep.swift`, `Sources/xpnd/Library/KeywordNamespace.swift:45-62`
- Test: `Tests/xpndTests/ExpansionEngineTests.swift`, `Tests/xpndTests/PlayerTests.swift`, `Tests/xpndTests/KeywordNamespaceTests.swift`

**Interfaces:**
- Consumes: Task 1's `KeyInput.boundary`, `Matcher.instant`, `Matcher.strict`, `Matcher.isBoundary`.
- Produces:
  - `extension [PlayStep] { var endsInText: Bool; func appendingText(_ s: String) -> [PlayStep] }` — `endsInText` is true
    when empty or the last step is `.paste` or `.moveLeft`. `appendingText` adds to the last paste (or adds a paste),
    and with a trailing `.moveLeft(n)` puts the text in the paste before it and returns `.moveLeft(n + s.count)`.
  - `Player.play(_ steps: [PlayStep], deletingCharacters: Int, tail: @MainActor () -> (text: String, typedSince: Int) = { ("", 0) }) async throws(ExpansionError)`:
    after `check`, calls `tail()` once, backspaces `deletingCharacters + typedSince`, plays `steps.appendingText(text)`
    (or `steps` when `text` is empty).

- [ ] **Step 1: Write failing tests.**
  - PlayerTests: `[.paste("ab"), .moveLeft(1)].appendingText(" x")` == `[.paste("ab x"), .moveLeft(3)]`;
    `[].appendingText(" ")` == `[.paste(" ")]`; `[.key(.enter, count: 1)].endsInText` false.
  - PlayerTests: `play([.paste("a")], deletingCharacters: 5, tail: { (" xy", 2) })` logs `["bs 7", "paste a xy"]`.
  - ExpansionEngineTests (add `Harness.space()` = `engine.handle(.boundary(" "))`):
    - `strictFiresOnSpace`: type `;sig`, nothing yet; `space()` → `["bs 5", "paste Best "]`.
    - `strictFiresOnPunctuation`: `;sig` then `.characters(".")` → `["bs 5", "paste Best."]`.
    - `looseStillFiresInstantly`: loose `==>` → `["bs 3", "paste →"]` without a boundary.
    - `keysTypedDuringExpansionAreKept`: snippet with `#{input:N}`; type `;sig`, `space()`, then `"a"`, `"b"` while the
      form gate is open (targetsXpnd false), answer `["N": "Ann"]` → `["bs 7", "paste Hi Ann ab"]`.
    - `otherKeyDuringExpansionStopsKeeping`: as above but `engine.handle(.reset)` after `"a"` → `["bs 5", "paste Hi Ann "]`.
    - `trailingKeyStepDropsBoundary`: snippet `Hi#{key:enter}`; `;s` + space → `["bs 3", "paste Hi", "key enter x1"]`.
    - Update existing strict tests (`matchTriggersExpansion`, `typingDuringExpansionIsIgnored`, …) to type a space and
      expect the extra backspace and trailing space.
  - KeywordNamespaceTests: `hidingNote` for strict `;d` beside strict `;db` is nil; for loose `;d` beside `;db` it's the
    existing note; a connection activation `;d` beside snippet `;db` still notes.
- [ ] **Step 2: Run** `swift test --filter 'ExpansionEngineTests|PlayerTests|KeywordNamespaceTests'` — FAIL.
- [ ] **Step 3: Implement.**
  - `handle`: after the `targetsXpnd` guard, if `isExpanding`, feed the input to the keep logic (`.characters`/`.boundary`
    append to `kept`, past 64 or any other input sets `kept = nil`) then reset the buffer and return. Otherwise, before
    `buffer.apply`, if the input is `.boundary(s)` or a one-character `.characters(s)` with `Matcher.isBoundary`, and
    `Matcher.strict(word: buffer.text, …, in: candidates)` returns a snippet, start it with
    `deletingCharacters: keyword.count + 1` and `boundary: s`. Otherwise apply and run today's instant path with
    `Matcher.instant`.
  - `start` sets `kept = ""` for typed-keyword runs only. `run` gains `boundary: String?` and passes
    `tail: { endsInText ? ((boundary ?? "") + (kept ?? ""), (kept ?? "").count) : ("", 0) }`, clearing `kept` inside.
  - `hidingNote`: a shorter string that is a **strict** snippet keyword doesn't hide a longer one (owner `.snippet(id)` →
    look up its `matching`). Update the doc comment.
- [ ] **Step 4: Run** `make test` — all PASS.
- [ ] **Step 5: Commit** `feat(expansion): expand strict keywords on a boundary and keep keys typed meanwhile`, including
  README's keyword paragraph (strict waits for space or punctuation, which is typed back; Return/Tab don't fire; `(`, `"`
  etc. may come first; loose fires at once) and CHANGELOG **Changed** + **Fixed** bullets.

### Task 3: One clipboard capture per expansion, restored after the app reads

**Files:**
- Modify: `Sources/xpnd/Expansion/KeystrokeSender.swift`, `Sources/xpnd/Expansion/Player.swift`
- Test: `Tests/xpndTests/PlayerTests.swift`, `Tests/xpndTests/SecretClipboardTests.swift`

**Interfaces:**
- Produces:
  - `KeystrokeSending.restoreClipboard() async` (protocol requirement; test fakes log `"restore"`).
  - `CGEventKeystrokeSender.write(_ text: String, to: NSPasteboard, floor: Duration, cap: Duration, margin: Duration, postCommandV: () -> Void) async -> Int`
    (static; returns `changeCount` after writing; returns once the promised `.string` was read and `margin` passed,
    no earlier than `floor` and no later than `cap`).
  - `CGEventKeystrokeSender.PasteSession` (static helpers `capture(_:)`/`restore(_:to:)` or an instance property —
    builder's choice) replacing `static func paste(_:on:settle:postCommandV:)`.
  - Constants: `pasteFloor = .milliseconds(150)`, `pasteCap = .seconds(1)`, `pasteReadMargin = .milliseconds(50)`.

- [ ] **Step 1: Write failing tests.**
  - PlayerTests: steps `[.paste("a"), .key(.tab, count: 1), .paste("b"), .runShortcut(name: "S"), .paste("c")]` log
    `[…, "paste a", "key tab x1", "paste b", "restore", "paste c", "restore"]` (restore before Run Shortcut, Open App,
    delay, and once at the end; not before keys).
  - PlayerTests: a failing `.openApp` mid-play still logs a final `"restore"`.
  - PlayerTests (real pasteboard, replace the two `paste…` tests): `write` then restore leaves `"original"`; a read inside
    `postCommandV` sees `"expanded"`; a newer copy during the wait isn't overwritten; with no read, `write` returns
    after ≥ cap (use cap 100 ms, floor 10 ms) and with a read returns before cap.
  - SecretClipboardTests: port the two `paste(…settle:)` tests to `write` + restore with the same timings.
- [ ] **Step 2: Run** `swift test --filter 'PlayerTests|SecretClipboardTests'` — FAIL.
- [ ] **Step 3: Implement.** The sender keeps `held: (snapshot: PasteboardSnapshot, written: Int)?`: `paste` captures
  only when `held` is nil, writes an `NSPasteboardItem` whose `.string` comes from an `NSPasteboardItemDataProvider`
  (records the read time, then sets the string) plus the two nspasteboard.org markers, under `.currentHostOnly`.
  `restoreClipboard` restores only if `changeCount == written`, then clears `held`. Keystroke mode never captures.
  `Player.play` restores before `.delay`, `.openApp`, `.runShortcut`, at the end, and on a thrown error.
- [ ] **Step 4: Run** `make test` — PASS.
- [ ] **Step 5: Commit** `fix(expansion): restore the clipboard once, after the app has read the paste` with a CHANGELOG **Fixed** bullet.

### Task 4: Combo limits and cycles

**Files:**
- Modify: `Sources/xpnd/Expansion/Evaluator.swift`, `Sources/xpnd/Expansion/ExpansionError.swift`
- Test: `Tests/xpndTests/EvaluatorTests.swift`

**Interfaces:**
- Produces: `ExpansionError.comboCycle(String)` — "The snippet “\(k)” includes itself, so it can't expand.";
  `ExpansionError.comboTooDeep` — "Snippets include each other too deeply to expand (over 16 levels or 10,000 pieces)."

- [ ] **Step 1: Write failing tests.** Replace `comboCycleLeftLiteral` with `comboCycleThrows` (`;a` → `#{combo:;b}`,
  `;b` → `#{combo:;a}` throws `.comboCycle(";a")`, also via `upper`). `deepNestingThrows`: 17 chained snippets throw
  `.comboTooDeep`. `explodingNestingThrows`: 15 levels of `#{combo:x}#{combo:x}` throws `.comboTooDeep` (finishes
  fast). 16 chained levels still expand.
- [ ] **Step 2: Run** `swift test --filter EvaluatorTests` — FAIL.
- [ ] **Step 3: Implement.** Both passes (`collectInputs`, `expand`) take the stack and an `inout` budget; depth is
  `stack.count`; each produced item (pass 2) and each visited variable (pass 1) costs one.
- [ ] **Step 4: Run** `swift test --filter EvaluatorTests` — PASS.
- [ ] **Step 5: Commit** `fix(expansion): stop snippet loops and runaway nesting with a clear message` + CHANGELOG.

### Task 5: Shortcuts list once, honest Shortcuts and script errors

**Files:**
- Modify: `Sources/xpnd/Expansion/ShortcutsList.swift`, `Sources/xpnd/Expansion/ActionRunner.swift`,
  `Sources/xpnd/Expansion/ProcessRunner.swift:146-166`, `Sources/xpnd/Expansion/ExpansionError.swift`,
  `Sources/xpnd/Settings/SnippetEditorView.swift:156`
- Test: `Tests/xpndTests/ActionRunnerTests.swift`, `Tests/xpndTests/ProcessRunnerTests.swift`, `Tests/xpndTests/PlayerTests.swift:47`

**Interfaces:**
- Produces: `ShortcutsList.fetch() async -> [String]?` (nil when the CLI fails); `ActionRunner.shortcutNames: @Sendable () async -> [String]?`;
  `ExpansionError.shortcutsUnavailable` — "Couldn't read your list of Shortcuts.";
  `ExpansionError.scriptNotExecutable(path:)` — "The script “\(path)” isn't executable. Run chmod +x on it."

- [ ] **Step 1: Write failing tests.** `check` with names `nil` throws `.shortcutsUnavailable`; `runShortcut` no longer
  calls `shortcutNames` (a counting closure stays at 0 calls). `ScriptRunner.run` on a temp file without +x throws
  `.scriptNotExecutable`; on a missing path `.scriptNotFound`.
- [ ] **Step 2: Run** `swift test --filter 'ActionRunnerTests|ProcessRunnerTests'` — FAIL.
- [ ] **Step 3: Implement.** `ScriptRunner` maps `.notExecutable` to `.scriptNotExecutable` when a regular file exists at
  `path`. The editor's chooser uses `await ShortcutsList.fetch() ?? []`.
- [ ] **Step 4: Run** `make test` — PASS.
- [ ] **Step 5: Commit** `fix(expansion): list Shortcuts once and name script and Shortcuts failures` + CHANGELOG.

### Task 6: Cheaper per-key namespace check and picker filtering

**Files:**
- Modify: `Sources/xpnd/Expansion/ExpansionEngine.swift:72-78`, `Sources/xpnd/Picker/PickerPanel.swift:37-99`

- [ ] **Step 1: Implement.** `refreshNamespace` keeps `seenSnippets`/`seenConnections` and, when they compare equal to the
  stores', assigns the stores' values so later compares share storage. `PickerView` holds `@State results`, set
  `onAppear` and in `onChange(of: query)`; `move` and `current` read it.
- [ ] **Step 2: Run** `make test` — PASS (behaviour unchanged; `PickerFilterTests`, `ExpansionEngineTests.libraryEditsReachTheMatcher`).
- [ ] **Step 3: Commit** `perf(expansion): skip deep library compares per key and refilter the picker once per query`.

### Task 7: Branch wrap-up

- [ ] Update `docs/DEVELOPMENT.md` where it describes matching, the paste settle, or `Player`.
- [ ] Run `make test` and `make app` — both succeed.
- [ ] Update `IMPLEMENTATION_PLAN.md` stage 1 status; commit `docs: …`.
- [ ] Push and `gh pr create`; the body lists by-hand checks: fast typing after `;sig` in TextEdit and Slack; `;sig`
  then Return in Messages (no expansion); a snippet in VS Code under load (clipboard restored, right text pasted);
  a Run Shortcut snippet that reads the clipboard; Screen Sharing (typed, unchanged).
