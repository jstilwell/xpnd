# Snippet Designer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Batch 4 of the review fixes: new snippet variables, a live preview, a form per variable, and highlighting that catches typos.

**Architecture:** One pure `Variable` type parses `#{name:argument}` into a typed value (or a problem) and writes it back as text. `Evaluator`, the checker behind the highlighting, the preview and the variable forms all go through it, so they can't disagree. The preview runs the real `Evaluator` with a `PreviewContext` that never reads the clipboard, the environment or a script, and turns keys and actions into labels.

**Tech Stack:** Swift 6, SwiftUI + AppKit (`NSTextView`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-20-review-fixes-design.md` (section "Batch 4", and "Approaches" item 5).

## Global Constraints

- `make test` passes and `make app` builds. One commit per change on `feature/snippet-designer`. No release commit.
- Argument escapes stay `\}` and `\\`. `#{input:Label=default}` splits at the first `=`. In `#{choice:Label:a|b|c}`, `\|` isn't supported (documented). The same label twice shares one field, and the first use sets its kind.
- A variable that won't parse still pastes its raw text, as today.
- `#{uuid}` is uppercase, like `uuidgen`. `#{fullName}` is `NSFullUserName()`. `#{date:+1d}` / `#{time:+2h}` are the short style, shifted with the existing shift syntax.
- `#{clipboard:trim|upper|lower}`, and the same for `#{selection:…}`. `trim` removes surrounding whitespace and newlines.
- `#{selection}`: only when the expansion came from the picker, and not in an app that gets keystrokes. xpnd sends ⌘C, waits up to 300 ms for the pasteboard to change, reads it, then puts the clipboard back. Otherwise it is empty.
- The preview never runs a script, presses a key, opens an app, runs a Shortcut, or reads the clipboard, the selection or the environment. Those show as labelled placeholders: `‹clipboard›`, `‹selection›`, `‹HOME›`, `‹output of /path›`. Keys and actions show as `⟨Tab⟩`, `⟨⌘⇧J⟩`, `⟨wait 500 ms⟩`, `⟨open Safari⟩`, `⟨run Shortcut “x”⟩`. The cursor shows as `‸`. An error shows its HUD message.
- Nothing logs or stores snippet text, the preview, or the selection.
- New Snippet from Clipboard refuses a concealed clipboard item (`org.nspasteboard.ConcealedType`, or a type starting with `SecretClipboard.secretTypePrefix`), and says so in a HUD.

## Review Focus

1. A value typed into a form that contains `}`, `\`, `=` or `:` (a default, a date format, a script path) expands to exactly what was typed, or the form refuses it. It never breaks the variable.
2. The clipboard after reading `#{selection}` is byte-for-byte what it was, both when the app copies and when it never does (nothing selected, a 300 ms timeout).
3. The preview of a snippet that includes another snippet with `#{shell:}`, `#{envVar:}` or `#{clipboard}` shows placeholders. Nothing runs or is read.
4. Highlighting while typing: no colour carries into newly typed text, it doesn't run during marked text from an input method, and ⌘Z undoes typing, never highlighting.
5. An input label used by both `#{input:}` and `#{choice:}` in one snippet, or across included snippets, gives one field, whose kind comes from the first use.

---

### Task 1: One parser for variables

**Files:** create `Sources/xpnd/Expansion/Variable.swift`. Modify `Evaluator.swift` (`resolve` switches on `Variable`) and `Template.swift` (ranges). Tests: new `VariableTests`, plus `TemplateTests`; `EvaluatorTests` must stay green.

**Interfaces:**
- `enum Variable: Equatable, Sendable`, one case per variable:
  - `clipboard(Transform?)`, `selection(Transform?)`, `date(shift: String?)`, `time(shift: String?)`
  - `dateTime(shift: String?, format: String)`, `snippet(keyword: String, Case)` (combo/upper/lower), `cursor`
  - `input(label: String, default: String)`, `choice(label: String, options: [String])`, `longInput(label: String)`
  - `envVar(String)`, `script(path: String, timeoutMs: Int?)`, `key(KeyName, count: Int)`, `shortcut(String)`, `delay(Int)`
  - `openApp(String)`, `runShortcut(String)`, `uuid`, `fullName`
- `enum Transform: String { trim, upper, lower }`; `enum Case { plain, upper, lower }`.
- `static func parse(name: String, argument: String?) -> Result<Variable, VariableProblem>`.
- `var template: String`: escapes `\` and `}`. `parse` of the parts of `template` gives back the same value.
- `struct VariableProblem: Error, Equatable { let message: String }`. The messages are the tooltip text: "xpnd has no variable “#{foo}”.", "“tabb” isn't a key name.", "“+1x” isn't a date shift.", "“abc” isn't a number of milliseconds.", "Input needs a label." and so on.
- `Template.parseWithRanges(_ text: String) -> [(token: TemplateToken, range: NSRange)]`, with ranges in UTF-16 for `NSTextView`.

- [ ] Tests: `parsesEveryVariable`, `templateRoundTripsThroughParse` (including a `}` and a `\` in an argument), `inputDefaultSplitsAtFirstEquals`, `choiceSplitsOptionsOnBar`, `problemsForUnknownNameAndBadArguments` (`#{key:tabb}`, `#{dateTime:+1x:yyyy}`, `#{delay:abc}`, `#{input}`, `#{date:x}`), `rangesAreUTF16` (an emoji before a variable).
- [ ] Watch them fail. Implement. Move `Evaluator.resolve` onto `Variable` with no behaviour change: the existing `EvaluatorTests` pass unchanged.
- [ ] Commit `refactor(expansion): parse variables once, for the evaluator and the editor`.

### Task 2: The new variables

**Files:** `Evaluator.swift`, `LiveEvaluationContext.swift`, `App/InputForm.swift`; tests `EvaluatorTests` (the `FakeContext` grows to match), `ExpansionEngineTests`.

**Interfaces:**
- `struct InputField: Equatable, Sendable { label: String; kind: Kind }`, with `enum Kind { text(default: String), choice([String]), multiline }`.
- `EvaluationContext` changes:
  - `askInputs(_ fields: [InputField]) async -> [String: String]?` replaces the labels version.
  - Adds `func selectedText() async -> String?` and `var fullName: String { get }`.
- `Evaluator.inputFields(_ snippet: Snippet, context:) throws(ExpansionError) -> [InputField]`: pass 1, made public for the preview. A repeated label keeps its first kind.
- `InputForm.ask(_ fields: [InputField])`:
  - a text field prefilled with its default
  - a `Picker` with the first option selected
  - a `TextEditor` about 4 lines tall for `multiline`, where Return makes a new line and ⌘Return inserts

- [ ] Tests:
  - `inputDefaultFillsTheField`
  - `choiceAsksWithItsOptions`
  - `sameLabelSharesOneFieldFirstKindWins`
  - `longInputAsksMultiline`
  - `uuidIsUppercase` (matches `^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$`, and differs between two uses)
  - `fullNameFromContext`
  - `dateAndTimeShift` (`#{date:+1d}` gives the short-style date of the next day, in UTC with `en_US_POSIX`)
  - `clipboardTransforms` (`"  Hi \n"` gives `Hi`, `HI` and `hi`)
  - `selectionTransforms`
- [ ] Watch them fail, implement, pass. Commit `feat(snippets): input defaults, choices, long input, uuid, full name, shifted dates and clipboard transforms`.

### Task 3: `#{selection}` from the picker

**Files:** create `Sources/xpnd/Expansion/SelectionCopy.swift`. Modify `ExpansionEngine.swift`, `LiveEvaluationContext.swift`, `AppDelegate.swift`; tests `ExpansionEngineTests`, new `SelectionCopyTests`.

**Interfaces:**
- `enum ExpansionTrigger { typed, picker }`.
- `ExpansionEngine`'s `makeContext` becomes `@MainActor (ExpansionTrigger) -> any EvaluationContext`. `expand(_:deletingCharacters:)` passes `.picker`, and a typed keyword passes `.typed`.
- `SelectionCopy.read(on: NSPasteboard, timeout: Duration = .milliseconds(300), press: @MainActor () async -> Void) async -> String?`:
  - sets the clipboard aside through `KeystrokeSender.setAside` / `restore`
  - presses
  - polls `changeCount` every 10 ms until the timeout
  - reads the string and restores the clipboard
  - returns nil on a timeout
- `LiveEvaluationContext(library:trigger:copy:)`. `selectedText()` returns nil unless `trigger == .picker` and `KeystrokeSender.typesKeystrokes(…)` is false.

- [ ] Tests:
  - `selectionReadsWhatThePressCopied`: a private `NSPasteboard(name:)`, and a press that writes to it.
  - `selectionTimesOutAndRestores`: the press does nothing.
  - `selectionRestoresTheClipboardExactly`: two items with several types each.
  - `pickerTriggerReachesTheContext` and `typedTriggerReachesTheContext`, in `ExpansionEngineTests`.
- [ ] Watch them fail, implement, pass. Commit `feat(snippets): #{selection} reads the selected text when a snippet comes from the picker`.

### Task 4: Highlighting and checks

**Files:** create `Sources/xpnd/Settings/TemplateCheck.swift`. Modify `TemplateTextView.swift` and `SnippetEditorView.swift` (pass the library and the snippet's keyword); tests new `TemplateCheckTests`, `TemplateTextViewTests`.

**Interfaces:**
- `struct TemplateMark: Equatable { range: NSRange; problem: String? }`.
- `TemplateCheck.marks(in text: String, keyword: String, library: SnippetLibrary) -> [TemplateMark]`:
  - one mark per variable
  - its problem comes from `Variable.parse`
  - or "No snippet has the keyword “k”.", or "This snippet can't include itself." for a snippet variable whose keyword is missing or is its own
- `TemplateTextView` takes `marks: [TemplateMark]`. On every change and update it:
  - resets the whole text's foreground colour and underline
  - colours good variables with `.systemBlue`
  - gives a problem a red thick underline and a `.toolTip`
  - sets attributes on the text storage inside `beginEditing`/`endEditing`, which registers no undo
  - skips the pass while `hasMarkedText()`
  - leaves `typingAttributes` as the plain font and colour

- [ ] Tests:
  - `marksGoodAndBadVariables`
  - `marksMissingAndSelfIncludingSnippets`
  - `highlightDoesNotTouchUndo`: apply marks, then `undoManager.canUndo` is false.
  - `typedTextAfterAVariableIsPlain`: `typingAttributes` has no blue.
- [ ] Watch them fail, implement, pass. Commit `feat(editor): colour variables and underline the ones that won't expand`.

### Task 5: Live preview

**Files:** create `Sources/xpnd/Settings/SnippetPreview.swift` (`PreviewContext`, `PreviewText`, and the `SnippetPreview` view). Modify `SnippetEditorView.swift`; tests new `SnippetPreviewTests`.

**Interfaces:**
- `struct PreviewContext: EvaluationContext`:
  - `init(library:, values: [String: String])`
  - placeholders as in Global Constraints
  - `runScript` returns `‹output of <path>›` and never runs it
  - `askInputs` returns `values`, with defaults filling any missing label
- `PreviewText.render(_ steps: [PlayStep]) -> String`:
  - keys show as `⟨Tab⟩`, or `⟨Tab ×3⟩` for a count
  - a shortcut shows as `⟨⌘⇧J⟩`
  - `⟨wait 500 ms⟩`
  - `⟨open <app name>⟩`, the last path part without `.app`
  - `⟨run Shortcut “x”⟩`
  - a trailing `moveLeft(n)` puts `‸` n characters before the end
- `SnippetPreview(snippet:library:)`:
  - shows a field per `Evaluator.inputFields`, prefilled, above a read-only monospaced box
  - re-evaluates in `.task(id:)` whenever the saved text or a value changes (the text saves after its 300 ms pause, which is the preview's pause)
  - an error shows `error.message` in red

- [ ] Tests:
  - `previewNeverReadsTheRealClipboard`: write a string to the general pasteboard and check the preview shows `‹clipboard›`.
  - `previewPlaceholdersForEnvAndScript`: through an included snippet too. The context records no `ScriptRunner` call, because it has no runner.
  - `previewRendersKeysShortcutsDelaysAndActions`
  - `previewShowsTheCursorMarker`
  - `previewUsesTypedValuesThenDefaults`
  - `previewShowsTheErrorMessage`: a missing combo.
- [ ] Watch them fail, implement, pass. Commit `feat(editor): a live preview of what a snippet will type`.

### Task 6: A form for each variable

**Files:** create `Sources/xpnd/Settings/VariableForm.swift`. Modify `SnippetEditorView.swift` (the menu), `TemplateTextView.swift` (menu for the right-click, and replace a range), `PlayStep.swift` (`KeyCombo.text(keyCode:modifiers:)`); tests new `VariableFormTests`, `TemplateTests`.

**Interfaces:**
- `enum VariableKind: CaseIterable` drives both the Insert Variable menu and the sheet. It has a title and a `blank: Variable` to start from.
- `VariableForm(variable: Variable, library:, done: (Variable) -> Void)` is a sheet with these fields:
  - **Input:** label and default
  - **Choice:** label and an options list (add, remove, reorder)
  - **Long Input:** label
  - **Date & Time:** format presets, custom format, shift, and a live sample using `PreviewContext`
  - **Date / Time (shifted):** the shift
  - **Key:** a `KeyName` picker and a count stepper
  - **Keyboard Shortcut:** `ShortcutRecorder`, converted with `KeyCombo.text`
  - **Other Snippet:** a searchable keyword list and plain/upper/lower
  - **Delay:** a stepper in ms
  - **Script:** a file picker and a timeout
  - **Clipboard / Selection:** the transform
  - **Insert** is disabled while the value has a problem: an empty label, a `|` in an option, or no options.
- Variables with no arguments insert directly: Cursor, UUID, Full Name, plain Date/Time/Date and Time. So do Open App… and Run Shortcut…, which keep today's pickers.
- `KeyCombo.text(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String?`: `Cmd+Shift+J` order, or nil for a key `KeyCombo.parse` can't take.
- `Template.variable(at utf16Offset: Int, in text: String) -> (range: NSRange, variable: Variable)?` serves the right-click. The text view's `menu(for:)` adds "Edit Variable…" when the click is inside a variable that parses. The form then replaces that range through `insertText(_:replacementRange:)`, so the change saves and can be undone.

- [ ] Tests:
  - `everyKindsBlankRoundTrips`
  - `formRefusesABarInAChoiceOption`
  - `keyComboTextRoundTripsThroughParse`
  - `variableAtFindsTheTokenUnderTheCaret`: start, middle and end, an offset just outside, and an emoji before it.
- [ ] Watch them fail, implement, pass. Commit `feat(editor): a form for each variable, and Edit Variable… on right-click`.

### Task 7: New Snippet from Clipboard

**Files:** `AppDelegate.swift` (a status menu item under Open Picker), `MainWindowController.swift` (`newSnippet(text:)`), `SnippetsSettingsView.swift` (`addSnippet(to:connections:text:)`, with `text` defaulting to `""`), `Main/EditorRules.swift`; tests `EditingRulesTests`, `MainWindowLogicTests`.

**Interfaces:**
- `EditorRules.clipboardSnippetText(types: [String], string: String?) -> Result<String, ClipboardRefusal>`. `ClipboardRefusal` is `.concealed` or `.noText`. HUD messages:
  - "The clipboard holds a password, so xpnd didn't make a snippet from it."
  - "The clipboard has no text to make a snippet from."

- [ ] Tests: `concealedClipboardIsRefused` (both types), `noTextIsRefused`, `clipboardTextBecomesTheSnippet`, `addSnippetWithText`.
- [ ] Watch them fail, implement, pass. Commit `feat(menus): New Snippet from Clipboard`.

### Task 8: Docs

- [ ] README: the variables table, including the `\|` limit and selection only from the picker; the preview, forms and highlighting; New Snippet from Clipboard.
- [ ] CHANGELOG bullets, and DEVELOPMENT (`Variable` is the one parser, plus `PreviewContext`).
- [ ] `IMPLEMENTATION_PLAN.md`: mark stage 4 Complete.
- [ ] Commit `docs: describe the new variables and the snippet designer, and mark stage 4 done`.
