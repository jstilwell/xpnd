# Connection Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Batch 2 of the review fixes: connecting is faster to start, survives slow password managers, and remembers what you use.

**Architecture:** Changes stay inside the existing layers. `SSHCommandBuilder` gains one flag, `ConnectionService` splits its one password phase into a clipboard phase (cancelled by the next connect) and a tab phase (not cancelled), `ConnectionFilter` gains pure shortlist/ranking helpers the launcher draws, `TerminalSessions.open` can replace an ended tab in place, and a new pure `SSHConfigImport` parser feeds the existing import preview.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Swift Testing, Yams.

**Spec:** `docs/superpowers/specs/2026-11-20-review-fixes-design.md` (section "Batch 2").

## Global Constraints

- `make test` passes and `make app` builds; one commit per change, Conventional Commits, on `feature/connection-improvements`.
- Never log, store or put in a fixture keystrokes, snippet text or passwords; recents store connection ids only.
- Processes get argv; SSH values refuse control characters; imported values never reach a shell unquoted.
- YAML stores save atomically; new YAML keys are optional so older files load.
- RDP password: provider → `XPRDPSession` memory only. An empty password stays unset, so FreeRDP prompts (`XPSetSecret`).
- SSH defaults: `-o ConnectTimeout=15 -o ServerAliveInterval=30`, after the connection's own options; toggle "Add a connect timeout and keepalive", on by default.
- Recents: up to 10 ids in `UserDefaults`; the launcher shows the last 5 distinct ones.
- Exit 255 reads "ssh couldn't connect (see the message above)".

## Review Focus

1. A second connect while Touch ID is up for an RDP tab: the first tab still opens, and the second connect isn't refused as busy.
2. A send-to-tab offer for tab A survives connecting to B (both offers live); a clipboard phase for A is still dropped.
3. An `~/.ssh/config` with `Host *`, `Match`, `Include`, quoted values, `Key=value` and duplicate keys (ssh keeps the first value).
4. The launcher with favourites that are also recents: each connection appears once in the shortlist, and arrow keys never select two rows.
5. Reconnecting an ended tab when the connect then fails: the ended tab stays, and a later connect doesn't silently replace another tab.

---

### Task 1: SSH connect timeout and keepalive

**Files:** `Sources/xpnd/Connections/SSHCommand.swift`, `Sources/xpnd/Connections/ConnectionService.swift`, `Sources/xpnd/App/AppSettings.swift`, `Sources/xpnd/App/AppDelegate+Connections.swift`, `Sources/xpnd/Settings/TerminalSettingsView.swift`; tests `SSHCommandTests`, `ConnectionServiceTests`, `AppSettingsTests`.

**Interfaces:** Produces `SSHCommandBuilder.build(_:in:keysDirectory:connectDefaults: Bool = false)`, `SSHCommandBuilder.connectDefaults: [String]`, `AppSettings.sshConnectDefaults: Bool` (default true), `ConnectionService.init(… sshConnectDefaults: @escaping @MainActor () -> Bool = { false } …)`.

- [ ] Tests: `connectDefaultsFollowTheConnectionsOwnOptions` (options `-o ConnectTimeout=5` come before `-o ConnectTimeout=15 -o ServerAliveInterval=30`, which come before the target and `-t`-free), `connectDefaultsAreOffByDefault`, `jumpHopsDontGetConnectDefaults`; `AppSettingsTests.sshConnectDefaultsStartOn`; `ConnectionServiceTests.connectDefaultsSettingReachesTheCommand`. Run, see them fail.
- [ ] Implement; Settings → Terminal toggle with help: "ssh gives up after 15 seconds and checks a quiet session every 30. These override ~/.ssh/config; turn this off if you set them there."
- [ ] Tests pass; commit `feat(connections): add a connect timeout and keepalive to ssh, on by default`.

### Task 2: Password phases and the RDP fetch

**Files:** `ConnectionService.swift`, `AppDelegate+Connections.swift`; test `ConnectionServiceTests`.

**Interfaces:** `passwordPhase` stays the clipboard phase (cancelled by the next connect and by `cancelPasswordPhase`). New `private(set) var tabPhase: Task<Void, Never>?` holds send-to-tab offers and the RDP open; the next connect doesn't cancel it, `cancelPasswordPhase` (window close) does. New init closure `waiting: @MainActor (String?) -> Void = { _ in }` (show text, nil hides), wired to `hud.show` / `hud.hide`.

- [ ] Tests: `rdpOpensAfterConnectReturns` (provider held: `connect` returns, then the tab opens on release), `rdpSaysItIsWaitingForThePasswordManager` ("Waiting for 1Password…"; "Waiting for the Keychain…" for a keychain ref; hidden after), `rdpMissingItemOpensTheTabSoFreeRDPAsks` (`.notFound` → tab with `""`, notify says the item wasn't found and Windows will ask), same for `.noPassword`, `rdpLockedStillStops`, `newerConnectKeepsATabOffer` (send mode: offer for A not cancelled by connecting B), existing `newerConnect…` tests stay green. Harness `connect` awaits both phases. Run, see them fail.
- [ ] Implement: RDP path does plan + `prepareToAct` inside the claim, then `tabPhase = Task { fetch; open }`, skipping the open if cancelled.
- [ ] Tests pass; commit `fix(connections): fetch RDP passwords outside the one-action claim and keep tab offers across connects`.

### Task 3: Drop-folder cleanup off the main thread

**Files:** `RDPDropFolder.swift`, `RDPHost.swift`, `AppDelegate.swift`; test `RDPDropFolderTests`.

**Interfaces:** `RDPDropFolder.clearInTurn(folder: URL) async`, `RDPDropFolder.applyLaunchCleanupInTurn(policy:now:) async`, both on the `copies` queue (after any queued copy).

- [ ] Tests: `clearInTurnRemovesTheFolderAfterAQueuedCopy`, `launchCleanupInTurnRemovesOldFolders`. Fail, implement, pass. Drop the shortcut comment the queue fixes.
- [ ] Commit `perf(rdp): clear drop folders on the copy queue, not the main thread`.

### Task 4: Notes and favourites in the model

**Files:** `Connection.swift`, `ConnectionYAML.swift`, `ConnectionFilter.swift`, `ConnectionEditorView.swift`, `CommittingTextField.swift`, `Sidebar.swift`; tests `ConnectionYAMLTests`, `ConnectionFilterTests`.

**Interfaces:** `Connection.notes: String?`, `Connection.favorite: Bool` (YAML `notes`, `favorite: true`, both omitted when empty/false). `CommittingTextField(…, axis: Axis = .horizontal)`.

- [ ] Tests: `notesAndFavoriteRoundTrip`, `oldFilesLoadWithoutThem`, `filterFindsNotes` (rank with the folder path). Fail, implement, pass.
- [ ] Editor: "Favorite" toggle in the first section, "Notes" multi-line field last. Sidebar menu: "Add to Favorites" / "Remove from Favorites".
- [ ] Commit `feat(connections): add notes and favorites`.

### Task 5: Recents and the launcher shortlist

**Files:** `ConnectionFilter.swift`, `ConnectionLauncherPanel.swift`, `AppSettings.swift`, `AppDelegate.swift`, `ConnectionService.swift`, `AppDelegate+Connections.swift`; tests `ConnectionFilterTests`, `ConnectionServiceTests`, `AppSettingsTests`.

**Interfaces:** `ConnectionFilter.recording(_ id:, in recents: [UUID]) -> [UUID]` (front, distinct, at most 10), `ConnectionFilter.shortlist(_ entries:, recents:) -> (favorites: [ConnectionEntry], recent: [ConnectionEntry])` (favourites in tree order; then up to 5 recents not already favourites, newest first; ids not in `entries` dropped), `filter(_:query:recents: [UUID] = [])` (ties: favourite, then recency, then name). `AppSettings.recentConnections: [UUID]`. `ConnectionService.init(… recordRecent: @escaping @MainActor (Connection.ID) -> Void = { _ in } …)`, called once something launched or opened.

- [ ] Tests: `recordingMovesToFrontAndCapsAtTen`, `shortlistSkipsFavoritesInRecentAndDropsDeleted`, `shortlistShowsFiveRecent`, `queryTiesPreferFavoritesThenRecent`, `connectRecordsARecent`, `failedConnectRecordsNothing`, `recentConnectionsRoundTrip`. Fail, implement, pass.
- [ ] Launcher: with an empty query, "Favorites" and "Recent" sections over the tree; selection keyed by section so a connection in two sections is two rows. Recents are pruned of deleted ids when recorded.
- [ ] Commit `feat(launcher): show favorites and recent connections first`.

### Task 6: Reconnect an ended SSH tab

**Files:** `TerminalSession.swift`, `TerminalWorkspace.swift`, `MainWindowController.swift`; test `TerminalSessionsTests`.

**Interfaces:** `TerminalSessions.open(_:for:color:replacing: TerminalSession.ID? = nil)` (an ended tab at that id is replaced in place; anything else appends), `TerminalSessions.endedText(_ status: Int32?) -> String`. The workspace gets `reconnect: (TerminalSession) -> Void`; the controller remembers the tab to replace per connection and connects through `duplicate`.

- [ ] Tests: `openReplacingAnEndedTabKeepsItsPosition`, `openReplacingALiveTabAppends`, `exit255SaysSSHCouldntConnect`. Fail, implement, pass.
- [ ] Commit `feat(terminal): reconnect an ended ssh tab in place`.

### Task 7: Import from `~/.ssh/config`

**Files:** Create `Sources/xpnd/Connections/SSHConfigImport.swift`; modify `ImportExportView.swift`; test `SSHConfigImportTests`.

**Interfaces:** `SSHConfigImport.parse(_ text: String) -> (library: ConnectionLibrary, notes: [String])`: one folder "SSH config"; one connection per `Host` block, named by its first name without `*`, `?` or `!` (a block with none is skipped and counted in a note); HostName → host (else the alias), User, Port, IdentityFile → `-i <quoted path>` in SSH options, ProxyJump → a text jump host; first value wins; `Key value` and `Key=value`, quotes, `#` comments; `Include` and `Match` noted as ignored; a value with a control character is dropped with a note. The preview sheet shows the notes.

- [ ] Tests: `parsesAHostBlock`, `skipsWildcardHostsWithANote`, `firstValueWins`, `equalsAndQuotes`, `ignoresIncludeAndMatchWithNotes`, `identityFileBecomesAQuotedOption`, `proxyJumpBecomesATextJumpHost`, `controlCharactersAreDropped`. Fail, implement, pass.
- [ ] Button "Import from SSH Config…" reads `~/.ssh/config` and goes through the same removing/conflicts/preview/merge path.
- [ ] Commit `feat(import): import hosts from ~/.ssh/config`.

### Task 8: Docs and the RDP frame-copy finding

- [ ] `CLAUDE.md` platform finding: `XPRDPView drawRect:` makes a `CGBitmapContextCreateImage` per draw (documented copy-on-write: a physical copy happens only when FreeRDP writes during the draw), and `XPEndPaint` queues one small block per frame whose `setNeedsDisplayInRect:` calls coalesce; unmeasured, so unchanged.
- [ ] README (favorites, recents, notes, ssh defaults, SSH config import, Reconnect), CHANGELOG bullets, `docs/DEVELOPMENT.md` (ConnectionService phases, SSHConfigImport), `IMPLEMENTATION_PLAN.md` stage 2 Complete.
- [ ] Commit `docs: describe the connection improvements and mark stage 2 done`.
