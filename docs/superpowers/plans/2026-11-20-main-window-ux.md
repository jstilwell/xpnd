# Main Window UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Batch 3 of the review fixes: undo instead of "can't be undone", fuller menus, and the small things a Mac app is expected to do.

**Architecture:** Undo is pure model code (where an item sat, put it back there; undo an import by diffing before/after against the current library), registered on the acting window's `UndoManager` by `ConnectionEditing` / `SnippetEditing` and the import views. The rest is SwiftUI/AppKit wiring over existing editing calls, with pure helpers where a rule can be tested.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-20-review-fixes-design.md` (section "Batch 3", and "Approaches" item 3).

## Global Constraints

- `make test` passes, `make app` builds; one commit per change on `feature/main-window-ux`.
- Undo lives in memory only (no snapshot on disk), puts back only what the action removed or moved, into the *current* library: at the old parent and position, or the end if that parent is gone. Never a whole-library snapshot.
- Undoing an import puts back each item it replaced and removes each one it added; an item edited since the import is left alone.
- The delete confirmation stays only for a non-empty folder or group.
- Keyword and activation fields save on Return, focus leaving, or a typing pause; the "already used" check shows while typing.
- ⌘⇧N is the notch's in a desktop tab, so New Connection gets no shortcut. New Snippet is ⌘N, Find is ⌘F, Minimize ⌘M.
- Starter snippet: group "Starter", snippet "Today's date", `;date` → `#{date}`, seeded once like the connections file.
- Never log or store snippet text; Copy Keyword copies the keyword only.

## Review Focus

1. Undo a delete after the file reloaded from disk (snippet ids change on reload): the snippet comes back by keyword, in its group found by name.
2. Undo a delete whose keyword or activation string was taken meanwhile: the save is refused with the usual message, nothing else changes.
3. Undo an import after editing one imported connection: that connection stays, the rest of the import is removed.
4. Undo a move after its target folder was deleted: the item stays where it is; nothing is lost.
5. Switching snippets within the save delay after typing a keyword: the typed keyword saves to the snippet it was typed in, never the next one.

---

### Task 1: Where an item sat, and putting it back

**Files:** `Sources/xpnd/Main/ConnectionEditing.swift` (ConnectionLibrary extension), `Sources/xpnd/Library/SnippetMove.swift`; tests `ConnectionLibraryTests`, `SnippetStoreTests`.

**Interfaces:** `struct ConnectionPlacement: Equatable { parent: ConnectionFolder.ID?; parentName: String?; index: Int }`; `ConnectionLibrary.placement(of: SidebarItem) -> ConnectionPlacement?`; `mutating restore(_ removed: Removed, at: ConnectionPlacement) -> Bool` (false if the id is already in the library; parent gone: a folder goes last at the top level, a connection into a new top-level folder named `parentName`); `mutating moveBack(_ item: SidebarItem, to: ConnectionPlacement) -> Bool`. `struct SnippetPlacement: Equatable { groupID, groupName: String, index: Int }`; `SnippetLibrary.placement(ofSnippet:)`, `restoreSnippet(_:at:)` (group by id, else name, else a new group named `groupName` last), `restoreGroup(_:at:)`, `snippetID(id:keyword:)` lookup.

- [ ] Tests: `restoreAConnectionAtItsPlace`, `restoreIntoAGoneFolderMakesOne`, `restoreAFolderAtTheTopLevel`, `restoreRefusesAnIDAlreadyThere`, `moveBackReturnsToTheOldPosition` (same-list reorder and cross-folder), `moveBackWithTheTargetGoneLeavesIt`; snippets: `restoreSnippetByGroupName`, `restoreSnippetIntoAGoneGroupMakesOne`, `restoreGroupAtItsIndex`. Fail, implement, pass, commit `feat(editing): record where an item sat and put it back there`.

### Task 2: Undoable delete and move

**Files:** `ConnectionEditing.swift`, `SnippetsSettingsView.swift` (SnippetEditing), `MainWindowController.swift`, `Sidebar.swift`, `EditorRules.deleteQuestion`; tests `MainWindowLogicTests`, `EditingRulesTests`.

**Interfaces:** `ConnectionEditing.delete(_:undo: UndoManager?)`, `move(_:to:at:undo:)`; `SnippetEditing.deleteSnippet(_:undo:)`, `deleteGroup(_:undo:)`, `moveSnippet(_:to:at:undo:)`, `moveGroup(_:to:undo:)`. Action names "Delete “X”" / "Move “X”". `deleteQuestion` returns nil for a connection and a snippet; a folder's message ends "You can undo this." instead of "This can't be undone." The views pass `@Environment(\.undoManager)`.

- [ ] Tests (real `UndoManager`, `groupsByEvent = false`): `undoDeleteConnectionPutsItBackWithoutTouchingLaterEdits`, `undoMoveConnection`, `undoDeleteSnippetAfterAReload`, `undoDeleteGroup`, `undoMoveSnippet`, `deleteQuestionOnlyForNonEmptyContainers`. Fail, implement, pass, commit `feat(editing): undo deleting and moving snippets, groups, connections and folders`.

### Task 3: Undoable, safer imports

**Files:** `ConnectionImport.swift`, `LibraryImport.swift`, `ImportExportView.swift`; tests `ConnectionImportTests`, `LibraryImportTests`.

**Interfaces:** `ConnectionImport.undo(before:after:in:) -> ConnectionLibrary`, `LibraryImport.undo(before:after:in:) -> SnippetLibrary` (snippets matched by keyword). Conflict alerts: Replace `role: .destructive`, Skip `.keyboardShortcut(.defaultAction)`. Action name "Import".

- [ ] Tests: `undoImportRemovesAddedAndRestoresReplaced`, `undoImportKeepsAnEditedImport`, `undoImportRevertsAFolderStringItTook`, `undoImportRemovesAddedFoldersOnlyIfEmpty`; snippets: `undoImportRemovesAddedSnippets`, `undoImportRestoresReplacedSnippets`, `undoImportKeepsAnEditedSnippet`. Fail, implement, pass, commit `feat(import): undo an import, and make Replace the destructive choice`.

### Task 4: Keyword and activation fields save on commit

**Files:** `CommittingTextField.swift` (a `commitsOnPause(_:_:)` view modifier: `task(id:)` after `saveDelay`, `onSubmit`, `onDisappear`, at quit), `SnippetEditorView.swift`, `ConnectionEditorView.swift`, `FolderEditorView.swift`, `DetailsPane.swift` (`SnippetDetails` gets `.id(id)` so a pending keyword flushes to its own snippet).

- [ ] UI only (no unit test: the save timing is SwiftUI's task scheduling); `make test` stays green. Commit `fix(editor): save keywords and activation strings when typing pauses, not on every key`.

### Task 5: Context menus

**Files:** `Sidebar.swift`, `SnippetsSettingsView.swift`; tests `EditingRulesTests`.

**Interfaces:** `SnippetEditing.duplicateSnippet(_:connections:) -> Snippet.ID?` (after the original, name via `uniqueName`, keyword the first free of `keyword2`, `keyword3`…), `SnippetGroupDetails` takes `focus: Binding<EditorFocus?>` for Rename.

- [ ] Tests: `duplicateSnippetGetsAFreeKeywordAfterTheOriginal`. Menus: snippet Duplicate, Enable/Disable, Move to Group ▸, Copy Keyword, Delete; group New Snippet, Rename, Enable/Disable, Delete…. Commit `feat(sidebar): fuller snippet and group menus`.

### Task 6: Main and status menus

**Files:** `AppDelegate.swift`, `MainWindowController.swift`, `Sidebar.swift` (`searchable(isPresented:)`), `GlobalShortcut.swift`, `SettingsWindow.swift`; tests `EditingRulesTests`, new cases in `AppSettingsTests` or `GlobalShortcut` tests.

**Interfaces:** `Shortcut.menuKeyEquivalent: String` (letter lowercased, "Space" → " ", F-keys → their function-key character) for status items; `EditorRules.snippetTarget(for:in:) -> SnippetGroup.ID?`; `MainWindowController.newSnippet()`, `newSnippetGroup()`, `newConnection()`, `find()`.

- [ ] Tests: `menuKeyEquivalentForLettersSpaceAndFunctionKeys`, `snippetTargetIsTheSelectionsGroupElseTheFirst`. App menu About, Hide ⌘H, Hide Others ⌥⌘H, Show All; File: New Snippet ⌘N, New Snippet Group, New Connection, Import…, Export… (Settings → Import/Export); Edit: Find ⌘F; Window: Minimize ⌘M. Status menu: Open Picker and Open Connection Launcher with their shortcuts. Commit `feat(menus): add File, Find, About, Hide and Minimize, and the launcher to the status menu`.

### Task 7: Details buttons, picker, disabled items, tooltips

**Files:** `FolderEditorView.swift`, `DetailsPane.swift`, `PickerPanel.swift`, `PickerFilter.swift`, `AppDelegate.swift`, `Sidebar.swift`, `RDPFields.swift`; tests `PickerFilterTests`.

**Interfaces:** `PickerPanel(store:engine:openApp:)`; `PickerFilter.groupNames(_ library:) -> [Snippet.ID: String]`.

- [ ] Tests: `groupNamesForActiveSnippets`. Folder Details: New Connection and Delete Folder… buttons. Picker: "No snippets match" / "No snippets yet" with Open xpnd, group name on each row. Sidebar: disabled snippet or snippet in a disabled group dimmed, `accessibilityValue("Off")`, tooltip. `.help` on icon-only buttons; one help line under RDP options. Commit `feat(ui): folder buttons, picker empty state and groups, and clearer disabled items`.

### Task 8: First run

**Files:** `YAMLFileStore.swift` (generic `seedIfFirstLaunch(defaults:key:with:)`), `ConnectionStore.swift`, `SnippetStore.swift` (`SnippetLibrary.starter()`), `AppDelegate.swift`, `WelcomeWindow.swift`; tests `SnippetStoreTests`, `ConnectionStoreTests` stay green.

- [ ] Tests: `snippetsSeedOnceOnFirstLaunch`, `starterHasTheDateSnippet`. Welcome ready screen: `MenuBarIcon.image()`, both shortcuts, "Add and edit snippets in the xpnd window (menu bar → Open xpnd…)." Commit `feat(onboarding): a starter date snippet and a clearer ready screen`.

### Task 9: Docs

- [ ] README (undo, menus, starter snippet), CHANGELOG, DEVELOPMENT (undo), IMPLEMENTATION_PLAN stage 3 Complete. Commit `docs: describe the main window changes and mark stage 3 done`.
