# Review fixes and additions

Design: `docs/superpowers/specs/2026-11-20-review-fixes-design.md`. One branch and PR per stage; each stage's
detailed plan is in `docs/superpowers/plans/`, written when the stage starts.

## Stage 1: Expansion reliability
**Goal**: Strict keywords wait for a word boundary; typing during an expansion is kept; one clipboard capture per
expansion, restored after the app reads; combo limits; clearer Shortcuts and script errors; cheaper per-key and picker work.
**Success Criteria**: `make test` passes; typing `;sig ` expands to `Best `; typing fast after a keyword keeps the keys.
**Tests**: `TypingTests`, `ExpansionEngineTests`, `PlayerTests`, `EvaluatorTests`, `ActionRunnerTests`, `ProcessRunnerTests`, `KeywordNamespaceTests`.
**Status**: Complete (`fix/expansion-reliability`, PR open)

## Stage 2: Connections
**Goal**: RDP fetch outside the engine claim, per-tab password offers, SSH timeout/keepalive setting, drop-folder cleanup
off main, favourites and recents, Reconnect, `~/.ssh/config` import, FreeRDP prompt fallback, notes, RDP frame-copy check.
**Success Criteria**: `make test` and `make app` pass; launcher shows favourites/recents with an empty query.
**Tests**: `ConnectionServiceTests`, `SSHCommandTests`, `ConnectionFilterTests`, `ConnectionImportTests`, `ConnectionYAMLTests`, `TerminalSessionsTests`.
**Status**: Complete (`feature/connection-improvements`, PR open)

## Stage 3: Main window and settings
**Goal**: Undo that restores only affected items, commit-on-save keyword fields, fuller context menus, standard menus,
status-menu launcher item, folder buttons, picker empty state, accessible disabled state, safer import, first-run help, tooltips.
**Success Criteria**: `make test` and `make app` pass; ⌘Z after a delete restores the item without touching later edits.
**Tests**: `MainWindowLogicTests`, `EditingRulesTests`, `SnippetStoreTests`, `ConnectionLibraryTests`, `LibraryImportTests`.
**Status**: Complete (`feature/main-window-ux`, PR open)

## Stage 4: Snippet variables and designer
**Goal**: New variables (input defaults, choice, longInput, selection, uuid, clipboard/selection transforms, date/time
shifts, fullName), live preview, variable forms, highlighting and checks, New Snippet from Clipboard.
**Success Criteria**: `make test` and `make app` pass; a typo like `#{key:tabb}` is underlined in the editor.
**Tests**: `EvaluatorTests`, `TemplateTests`, `TemplateTextViewTests`, new `VariableTests`, `TemplateCheckTests`,
`SnippetPreviewTests`, `VariableFormTests`, `SelectionCopyTests`.
**Status**: Complete (`feature/snippet-designer`)

## After stage 4
PR to `~/code/websites/xpnd.dev` for the new features; remove this file and the plans/spec once all have merged.
