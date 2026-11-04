# Built-in Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SSH sessions open as tabs in a SwiftTerm terminal filling the right side of xpnd's main window, with the editor as an overlay, routing rules for typed activations, and settings for font, colours, cursor and scrollback.

**Architecture:** A `TerminalSessions` model (pure, tested with a fake host) owns sessions whose process and view come from a `TerminalHost`; the live host wraps SwiftTerm's `LocalProcessTerminalView`. `LaunchPlanner` gains a `.builtInTab` plan that `ConnectionService` hands to an injected `openTab` closure instead of the executor; `AppDelegate` wires that to the window, exempts a focused terminal from the "keys aimed at xpnd" reset, and asks before terminating live sessions. `MainView` swaps `DetailsPane` for a `TerminalWorkspace` while sessions exist.

**Tech Stack:** Swift 6, SwiftUI + AppKit, SwiftPM, Swift Testing, SwiftTerm 1.99.2 (2.0 API).

**Spec:** `docs/superpowers/specs/2026-11-03-built-in-terminal-design.md`

## Global Constraints

- Dependency: `.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.2")`, product `SwiftTerm`. No other new package. Note its transitive pins and `SwiftTermBuildInfoPlugin` in the PR.
- macOS 14+, Swift 6 language mode; `make test` must stay green; `make app` before the PR.
- Never log, persist, or put in a fixture: terminal output, scrollback, keystrokes, snippet text, secrets. xpnd never writes a secret to the PTY.
- `ssh` runs as argv (`/usr/bin/ssh` + `SSHCommand.arguments.dropFirst()`, `execName: "ssh"`), never through a shell.
- Session environment: the process's own environment plus `TERM=xterm-256color`, `COLORTERM=truecolor`, and `LANG=<Locale.current.identifier, any "@…" suffix dropped>.UTF-8` only when `LANG` is absent.
- UI copy: "Built-in terminal" (settings section), "xpnd (built-in)" (no-terminal picker), "Session ended (exit N)" / "Session ended (signal)", "Terminate N sessions?" with buttons "Terminate" and "Cancel" (singular: "Terminate 1 session?").
- Defaults: system monospaced font 13 pt, scheme follows system, blinking block cursor, 10 000 lines of scrollback.
- A known limit gets a `// shortcut: <limit>, <when to upgrade>` comment. Conventional Commits; branch `feature/built-in-terminal`.

## Review Focus

1. A session's process exits after its tab was already closed (or exits twice): `ended` for an unknown id must be a no-op, never a crash or a phantom tab. (Test in Task 4.)
2. `/usr/bin/ssh` fails to start (missing, not executable, PTY failure): the tab must show an ended state, not stay "running" forever. (Test in Task 4: a host reporting start failure maps to `.ended(nil)`.)
3. The connection behind a tab is deleted or edited while the tab is open: Duplicate goes through `connect`, which flashes "That connection no longer exists." and opens nothing; the open tab keeps running. (Covered by the existing `ConnectionService` guard; the Task 3 test asserts no tab opens for a missing id.)
4. Terminate is confirmed while a password phase (Touch ID / sudo offer) is still pending: the phase is cancelled with the sessions so no secret lands on the clipboard afterwards. (Test in Task 3: `terminateAll` hook cancels `passwordPhase`.)
5. A typed activation while the overlay editor's text field has focus: the key targets xpnd and the first responder is not a terminal, so nothing expands and the buffer resets — the field keeps its text. (Test in Task 7: `targetsXpndForExpansion(terminalFocused:)` truth table.)

---

### Task 1: Dependency and `BuiltInTerminalSettings`

**Files:**
- Modify: `Package.swift`
- Create: `Sources/xpnd/Terminal/BuiltInTerminalSettings.swift`
- Modify: `Sources/xpnd/App/AppSettings.swift` (Key enum, stored property, init)
- Test: `Tests/xpndTests/BuiltInTerminalSettingsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct BuiltInTerminalSettings: Codable, Hashable, Sendable {
      enum Scheme: String, Codable, CaseIterable, Sendable { case system, light, dark }
      enum Cursor: String, Codable, CaseIterable, Sendable { case block, bar, underline }
      /// nil is the system monospaced font.
      var fontName: String?
      var fontSize: Double
      var scheme: Scheme
      var cursor: Cursor
      var cursorBlinks: Bool
      var scrollback: Int
      static let standard: BuiltInTerminalSettings  // nil, 13, .system, .block, true, 10_000
  }
  ```
  `AppSettings.shared.builtInTerminal: BuiltInTerminalSettings` (UserDefaults key `builtInTerminal`, JSON like `terminal`).

- [ ] **Step 1: Add SwiftTerm to `Package.swift`** — the exact pin above in `dependencies`, `.product(name: "SwiftTerm", package: "SwiftTerm")` in the executable target. Run `swift package resolve` and check `Package.resolved` names `SwiftTerm` at `1.99.2`.
- [ ] **Step 2: Write the failing tests**
  ```swift
  @Test func standardDefaults() {
      let s = BuiltInTerminalSettings.standard
      #expect(s.fontName == nil && s.fontSize == 13 && s.scheme == .system && s.cursor == .block && s.cursorBlinks && s.scrollback == 10_000)
  }
  @Test func roundTripsThroughJSON() throws {
      var s = BuiltInTerminalSettings.standard
      s.fontName = "Menlo"; s.scheme = .dark; s.cursor = .bar; s.cursorBlinks = false; s.scrollback = 2000
      let data = try JSONEncoder().encode(s)
      #expect(try JSONDecoder().decode(BuiltInTerminalSettings.self, from: data) == s)
  }
  @MainActor @Test func appSettingsPersists() {
      let defaults = UserDefaults(suiteName: "BuiltInTerminalSettingsTests-\(UUID())")!
      let settings = AppSettings(defaults: defaults)
      #expect(settings.builtInTerminal == .standard)
      settings.builtInTerminal.fontSize = 15
      #expect(AppSettings(defaults: defaults).builtInTerminal.fontSize == 15)
  }
  ```
- [ ] **Step 3: Run** `swift test --filter BuiltInTerminalSettingsTests` — expected: compile failure (type missing).
- [ ] **Step 4: Implement** the struct and the `AppSettings` property following the `terminal` pattern (`defaults.data` → `JSONDecoder`, `?? .standard`; `didSet` encodes).
- [ ] **Step 5: Run** `swift test --filter BuiltInTerminalSettingsTests` — expected: 3 passed. Then `swift build` — SwiftTerm compiles.
- [ ] **Step 6: Commit** `build: add SwiftTerm 1.99.2` (Package files) and `feat(terminal): built-in terminal settings model`.

### Task 2: Routing — `.builtInTab` plan and the "xpnd (built-in)" choice

**Files:**
- Modify: `Sources/xpnd/Connections/TerminalSettings.swift` (`NoTerminalAction`)
- Modify: `Sources/xpnd/Connections/LaunchPlanner.swift` (`LaunchPlan`, `plan`)
- Modify: `Sources/xpnd/Connections/SSHCommand.swift` (add `Sendable` to `SSHCommand`)
- Modify: `Sources/xpnd/Connections/LaunchExecutor.swift` (`LiveLaunchExecutor.execute` switch)
- Modify: `Sources/xpnd/Settings/TerminalSettingsView.swift` (`Mode`, `modes`, `label`, `save`)
- Test: `Tests/xpndTests/LaunchPlannerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum NoTerminalAction { case preset(TerminalPreset, newTab: Bool), custom(template: String), builtIn }
  enum LaunchPlan { …, case builtInTab(SSHCommand) }
  static func plan(_ command: SSHCommand, frontBundleID: String?, settings: TerminalSettings,
                   preferBuiltIn: Bool = false) throws(LaunchError) -> LaunchPlan
  ```
  `preferBuiltIn` (the action came from xpnd's window or a focused xpnd terminal) wins over everything; then a front terminal types; then `whenNoTerminal`, where `.builtIn` → `.builtInTab(command)`.

- [ ] **Step 1: Write the failing tests** in `LaunchPlannerTests`
  ```swift
  @Test func preferBuiltInWinsEvenWithATerminalInFront() throws {
      #expect(try LaunchPlanner.plan(line, frontBundleID: "com.apple.Terminal", settings: .standard, preferBuiltIn: true) == .builtInTab(line))
  }
  @Test func builtInIsTheNoTerminalChoice() throws {
      #expect(try plan(line, .builtIn) == .builtInTab(line))
      #expect(try LaunchPlanner.plan(line, frontBundleID: "com.apple.Terminal", settings: settings(.builtIn)) == .typeIntoFrontTerminal(line.shellLine))
  }
  @Test func builtInActionRoundTripsThroughJSON() throws {
      let data = try JSONEncoder().encode(settings(.builtIn))
      #expect(try JSONDecoder().decode(TerminalSettings.self, from: data).whenNoTerminal == .builtIn)
  }
  ```
- [ ] **Step 2: Run** `swift test --filter LaunchPlannerTests` — expected: compile failure.
- [ ] **Step 3: Implement**: the enum cases; `plan` checks `preferBuiltIn` first; `LiveLaunchExecutor.execute` throws `LaunchError.failed("The built-in terminal opens from the xpnd window.")` for `.builtInTab` (the service never sends it there); in `TerminalSettingsView` add `Mode.builtIn`, list it first in `modes`, label "xpnd (built-in)", map both ways in the mode↔action conversions.
- [ ] **Step 4: Run** `swift test` — expected: all pass (existing planner tests unchanged).
- [ ] **Step 5: Commit** `feat(connections): route connects to the built-in terminal`.

### Task 3: `ConnectionService` opens a tab

**Files:**
- Modify: `Sources/xpnd/Connections/ConnectionService.swift` (init, `connect`, `plan(for:in:)`, `launch`)
- Modify: `Sources/xpnd/App/AppDelegate+Connections.swift` (`makeConnectionService`, `connectExclusively`)
- Test: `Tests/xpndTests/ConnectionServiceTests.swift`

**Interfaces:**
- Consumes: `LaunchPlan.builtInTab`, `plan(…, preferBuiltIn:)` (Task 2).
- Produces:
  ```swift
  // ConnectionService.init gains, after `executor:`:
  openTab: @escaping @MainActor (SSHCommand, Connection) -> Void
  func connect(_ id: Connection.ID, typedInto target: pid_t?, deletingCharacters: Int = 0, sudo: Bool = false,
               preferBuiltIn: Bool = false) async
  func cancelPasswordPhase()   // for Terminate
  // AppDelegate:
  func connectExclusively(_ id: Connection.ID, from pid: pid_t?, deleting: Int = 0, sudo: Bool = false,
                          preferBuiltIn: Bool = false) async
  ```
  `launch` handles `.builtInTab(command)`: after `stillInFront` and the backspaces, calls `openTab(command, connection)` and returns true; the executor is never called. The password phase runs as for any launch. `AppDelegate` passes `openTab: { _, _ in }` for now (Task 7 wires it).

- [ ] **Step 1: Write the failing tests**. The file's harness gets `var opened: [(SSHCommand, Connection)] = []`, its `service()` passes `openTab: { [unowned self] in opened.append(($0, $1)); log.events.append("tab \($1.name)") }`, and its `connect` helper gains `preferBuiltIn: Bool = false`. `aws` is the file's existing password-login connection.
  ```swift
  @Test func preferBuiltInOpensATabAndStillCopiesThePassword() async throws {
      let h = try Harness(aws)   // the file's fixture type
      await h.connect(aws, typedInto: nil, preferBuiltIn: true)
      #expect(h.opened.count == 1 && h.opened[0].1.id == aws.id && h.opened[0].0.arguments.first == "ssh")
      #expect(h.executor.plans.isEmpty)
      #expect(h.log.events == ["tab aws", "password login", "copy secret-login", "notify Password copied for aws"])
  }
  @Test func missingConnectionOpensNoTab() async throws {
      let h = try Harness(aws)
      await h.service().connect(UUID(), typedInto: nil, preferBuiltIn: true)
      #expect(h.opened.isEmpty && h.log.events == ["notify That connection no longer exists."])
  }
  @Test func cancelPasswordPhaseStopsIt() async throws {
      let h = try Harness(aws)
      h.provider.held = ["login"]   // the fixture's way of holding a password fetch open
      let service = h.service()
      await service.connect(aws.id, typedInto: nil, preferBuiltIn: true)
      service.cancelPasswordPhase()
      #expect(service.passwordPhase == nil)
      #expect(!h.log.events.contains { $0.hasPrefix("copy") })
  }
  ```
- [ ] **Step 2: Run** `swift test --filter ConnectionServiceTests` — expected: compile failure.
- [ ] **Step 3: Implement** per Interfaces; `cancelPasswordPhase` cancels and nils `passwordPhase`.
- [ ] **Step 4: Run** `swift test` — expected: all pass.
- [ ] **Step 5: Commit** `feat(connections): hand built-in tabs to the window`.

### Task 4: `TerminalSessions` model

**Files:**
- Create: `Sources/xpnd/Terminal/TerminalSession.swift`
- Test: `Tests/xpndTests/TerminalSessionsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// What a session runs in: its view and process. The live one wraps SwiftTerm (Task 5).
  @MainActor protocol TerminalHost: AnyObject {
      var view: NSView { get }
      /// Called once, on the main actor: exit status 0–255, or nil for a signal or a failed start.
      var onExit: ((Int32?) -> Void)? { get set }
      func terminate()
      func apply(_ settings: BuiltInTerminalSettings)
  }
  @MainActor @Observable final class TerminalSession: Identifiable {
      enum State: Equatable { case running, ended(Int32?) }
      let id: UUID; let connectionID: Connection.ID; let name: String; let color: ItemColor?
      let host: any TerminalHost
      private(set) var state: State
      var isLive: Bool  // state == .running
  }
  @MainActor @Observable final class TerminalSessions {
      init(makeHost: @escaping @MainActor (SSHCommand) -> any TerminalHost)
      private(set) var sessions: [TerminalSession]
      var selected: TerminalSession.ID?
      var liveCount: Int
      @discardableResult func open(_ command: SSHCommand, for connection: Connection, color: ItemColor?) -> TerminalSession.ID
      func close(_ id: TerminalSession.ID)      // terminates if live, removes, selects the neighbour
      func terminateAll()                      // terminates every live session, clears all
      static func terminateQuestion(count: Int) -> String   // "Terminate 1 session?" / "Terminate 3 sessions?"
  }
  ```
  Exit handling (private `ended(id, status)` set as the host's `onExit`): status 0 → remove and select the neighbour (the tab after it, else the one before, else nil); otherwise `state = .ended(status)`, tab stays. Unknown id → no-op. Opening selects the new session. Name and colour are snapshots.

- [ ] **Step 1: Write the failing tests** with a `FakeHost` (`view = NSView()`, `terminated` flag, `func exit(_ status: Int32?) { onExit?(status) }`) and `makeHost` capturing the hosts in order.
  ```swift
  @Test func openSelectsAndCountsLive()         // open two → sessions.count == 2, selected == second, liveCount == 2
  @Test func cleanExitClosesAndSelectsNeighbour() // open a,b,c; select b; hosts[1].exit(0) → sessions == [a,c], selected == c.id
  @Test func lastCleanExitLeavesNoSelection()     // open a; exit(0) → sessions empty, selected nil
  @Test func errorExitKeepsTheTab()               // exit(255) → state == .ended(255), liveCount == 0, still in sessions
  @Test func signalExitIsEndedNil()               // exit(nil) → .ended(nil)
  @Test func closeTerminatesLiveOnly()            // close a live one → host.terminated; close an ended one → not terminated again; both removed
  @Test func exitAfterCloseIsIgnored()            // close a; hosts[0].exit(0) → no crash, sessions unchanged
  @Test func terminateAllClears()                 // 2 live + 1 ended → every live host terminated, sessions empty, selected nil
  @Test func terminateQuestionPluralises()        // count 1 → "Terminate 1 session?", 3 → "Terminate 3 sessions?"
  ```
- [ ] **Step 2: Run** `swift test --filter TerminalSessionsTests` — expected: compile failure.
- [ ] **Step 3: Implement** per Interfaces; `terminateQuestion` uses `EditorRules.count(count, "session")`.
- [ ] **Step 4: Run** `swift test --filter TerminalSessionsTests` — expected: 9 passed.
- [ ] **Step 5: Commit** `feat(terminal): session model with tabs, exits and terminate`.

### Task 5: Live host on SwiftTerm

**Files:**
- Create: `Sources/xpnd/Terminal/LiveTerminalHost.swift`
- Create: `Sources/xpnd/Terminal/BuiltInTerminalSettings+SwiftTerm.swift`
- Test: `Tests/xpndTests/LiveTerminalHostTests.swift` (environment and mapping only; no process is started)

**Interfaces:**
- Consumes: `TerminalHost` (Task 4), `BuiltInTerminalSettings` (Task 1).
- Produces:
  ```swift
  @MainActor final class LiveTerminalHost: NSObject, TerminalHost, LocalProcessTerminalViewDelegate {
      init(command: SSHCommand, settings: BuiltInTerminalSettings)   // creates the view with TerminalOptions(cursorStyle:, scrollback:), applies settings, starts /usr/bin/ssh
      static func environment(from parent: [String: String], locale: String) -> [String]  // "KEY=VALUE" entries per Global Constraints
  }
  extension BuiltInTerminalSettings {
      var nsFont: NSFont                       // fontName ?? NSFont.monospacedSystemFont(ofSize:weight: .regular)
      var cursorStyle: CursorStyle             // block/bar/underline × blinks → SwiftTerm's six cases
      func colors(dark: Bool) -> (foreground: NSColor, background: NSColor)  // scheme .system follows `NSApp.effectiveAppearance`
  }
  ```
  `apply` sets `view.font`, `nativeForegroundColor/nativeBackgroundColor`, `setCursorStyle`. Scrollback is fixed at creation (`// shortcut: scrollback applies to new sessions, upgrade if SwiftTerm exposes a setter`). `processTerminated` and `processFailedToStart` forward to `onExit` (failed start → nil) exactly once. `terminate()` calls the view's `terminate()`. The view's `optionAsMetaKey` stays true.

- [ ] **Step 1: Write the failing tests**
  ```swift
  @Test func environmentAddsTermAndLocaleOnlyWhenMissing() {
      let env = LiveTerminalHost.environment(from: ["HOME": "/u", "LANG": "de_DE.UTF-8"], locale: "en_US")
      #expect(env.contains("TERM=xterm-256color") && env.contains("COLORTERM=truecolor") && env.contains("LANG=de_DE.UTF-8") && env.contains("HOME=/u"))
      #expect(LiveTerminalHost.environment(from: [:], locale: "en_US@rg=gbzzzz").contains("LANG=en_US.UTF-8"))
  }
  @Test func cursorStyleMapping() {
      var s = BuiltInTerminalSettings.standard
      #expect(s.cursorStyle == .blinkBlock)
      s.cursorBlinks = false; s.cursor = .bar
      #expect(s.cursorStyle == .steadyBar)
  }
  ```
- [ ] **Step 2: Run** `swift test --filter LiveTerminalHostTests` — expected: compile failure.
- [ ] **Step 3: Implement** per Interfaces. Start with `startProcess(executable: "/usr/bin/ssh", args: Array(command.arguments.dropFirst()), environment: …, execName: "ssh")`.
- [ ] **Step 4: Run** `swift test` — expected: all pass; `swift build` clean of warnings in the new files.
- [ ] **Step 5: Commit** `feat(terminal): SwiftTerm host for a session`.

### Task 6: Workspace UI — tabs, terminal, ended bar, editor overlay

**Files:**
- Create: `Sources/xpnd/Terminal/TerminalWorkspace.swift` (tab bar, `TerminalHostView: NSViewRepresentable`, ended bar, shortcuts)
- Modify: `Sources/xpnd/Main/MainWindowController.swift` (`MainWindowModel.editorShown`, `MainView` detail column, `MainWindowController` owns `TerminalSessions`, `terminalHasFocus`, `windowShouldClose`)
- Modify: `Sources/xpnd/Main/Sidebar.swift` only if the connect closure needs the overlay hidden (see below)

**Interfaces:**
- Consumes: `TerminalSessions`, `TerminalSession` (Task 4); `LiveTerminalHost` (Task 5).
- Produces:
  ```swift
  // MainWindowController
  let sessions: TerminalSessions
  var terminalHasFocus: Bool          // window.firstResponder is a SwiftTerm TerminalView (or a descendant of a session's view)
  // init gains: duplicate: @escaping (Connection.ID) -> Void   (wired in Task 7 to connectExclusively(preferBuiltIn: true))
  struct TerminalWorkspace: View {
      let sessions: TerminalSessions
      let duplicate: (Connection.ID) -> Void
      let settings: BuiltInTerminalSettings      // re-applied to every host on change
  }
  ```
  Behaviour: `MainView` shows `DetailsPane` when `sessions.sessions.isEmpty`, else `TerminalWorkspace` with `.overlay` of the editor card when `model.editorShown` (the card: `DetailsPane` in a `RoundedRectangle` material background, a "Close" `Button` top-right with `.keyboardShortcut(.cancelAction)`, inset 24 pt). `editorShown` becomes true when `model.selection` changes while sessions exist, false when the user closes it; the window's `connect` closure (double-click) sets it false after connecting. Closing the overlay makes the selected session's view first responder. Tab bar: one row, each tab shows the name in `color?.ui ?? .primary`, an "ended" marker for `.ended`, an "×" button; `.contextMenu { Button("Duplicate") { duplicate(session.connectionID) }; Button("Close") }`; selected tab highlighted. Ended bar under the terminal of an ended session: "Session ended (exit N)" or "Session ended (signal)" and a "Close" button. Shortcuts via `.keyboardShortcut` on hidden buttons inside the workspace: ⌘W closes the selected tab (an `NSAlert` "Terminate 1 session?" if live), ⌘⇧] / ⌘⇧[ cycle, ⌘1–⌘9 select by position. `windowShouldClose`: if `sessions.liveCount > 0`, `NSAlert` with `terminateQuestion`, buttons "Terminate" / "Cancel"; Terminate → `sessions.terminateAll()` and `cancelPasswordPhase` via a closure the delegate supplies (Task 7), then close. The detail column gets `.navigationSplitViewColumnWidth(min: 480, ideal: 700)`. Selecting a tab or opening one calls `window.makeFirstResponder(host.view)`.

- [ ] **Step 1: Implement** the views and controller changes per Interfaces (no unit tests: this is UI). Construct `TerminalSessions(makeHost: { LiveTerminalHost(command: $0, settings: AppSettings.shared.builtInTerminal) })` in the controller.
- [ ] **Step 2: Build and run** `make run`, then by hand: double-click an SSH connection → tab opens with a live session and keyboard focus; second connection → second tab; right-click a tab → Duplicate (does nothing until Task 7) and Close; single-click a sidebar item → overlay with Close; Esc closes it and the terminal types again; `exit` in the session → tab closes; a bad host (`ssh` exit 255) → tab stays with the ended bar; close the window with a live session → the alert; Cancel keeps it.
- [ ] **Step 3: Run** `swift test` — expected: all pass.
- [ ] **Step 4: Commit** `feat(window): terminal workspace with tabs and an editor overlay`.

### Task 7: App wiring — open tabs, expansion in tabs, routing, quit

**Files:**
- Modify: `Sources/xpnd/App/AppDelegate+Connections.swift` (`makeConnectionService` `openTab`, `showMainWindow` passing `duplicate`, `activate`, quick-menu connect)
- Modify: `Sources/xpnd/App/AppDelegate.swift` (tap `onKey`, `applicationShouldTerminate`)
- Create: `Sources/xpnd/App/ExpansionTargeting.swift` (one pure function)
- Test: `Tests/xpndTests/ExpansionTargetingTests.swift`

**Interfaces:**
- Consumes: `connect(…, preferBuiltIn:)`, `cancelPasswordPhase` (Task 3); `MainWindowController.sessions`, `terminalHasFocus`, `duplicate:` (Task 6).
- Produces:
  ```swift
  /// Keys aimed at xpnd reset the buffer, except in a focused built-in terminal, which expands like any app.
  enum ExpansionTargeting { static func targetsXpnd(keyTargetsProcess: Bool, terminalFocused: Bool) -> Bool }
  ```
  Wiring: `openTab` → `showMainWindow(selecting: nil)` then `mainWindow!.sessions.open(command, for: connection, color: connections.library.color(for: .connection(connection.id))?.color)` (`ResolvedColor.color: ItemColor`). `duplicate` → `Task { await connectExclusively(id, from: nil, preferBuiltIn: true) }`. The window's existing `connect` closure → `preferBuiltIn: true`. `activate` and the quick-menu/launcher connects pass `preferBuiltIn: mainWindow?.terminalHasFocus == true`. Tap: `engine.handle($0, targetsXpnd: ExpansionTargeting.targetsXpnd(keyTargetsProcess: $1, terminalFocused: self?.mainWindow?.terminalHasFocus ?? false))`. `applicationShouldTerminate`: `liveCount > 0` → the same alert as `windowShouldClose`; Terminate → `terminateAll()`, `service.cancelPasswordPhase()`, `.terminateNow`; Cancel → `.terminateCancel`. Give the controller's close path the same cancel closure.

- [ ] **Step 1: Write the failing test**
  ```swift
  @Test func onlyAFocusedTerminalIsExempt() {
      #expect(!ExpansionTargeting.targetsXpnd(keyTargetsProcess: false, terminalFocused: false))
      #expect(!ExpansionTargeting.targetsXpnd(keyTargetsProcess: false, terminalFocused: true))
      #expect(ExpansionTargeting.targetsXpnd(keyTargetsProcess: true, terminalFocused: false))
      #expect(!ExpansionTargeting.targetsXpnd(keyTargetsProcess: true, terminalFocused: true))
  }
  ```
- [ ] **Step 2: Run** `swift test --filter ExpansionTargetingTests` — expected: compile failure.
- [ ] **Step 3: Implement** the function and the wiring per Interfaces.
- [ ] **Step 4: Run** `swift test` — expected: all pass. `make run`, then by hand: `;prod` typed inside a tab → quick menu → pick → new tab; a snippet keyword typed in a tab expands there; the same keyword typed in the overlay's name field does not; `;aws` typed in Terminal.app still types into Terminal; Duplicate on a tab opens a second session and the password HUD/clipboard behaves as for a normal connect; Quit with a live session → alert; Terminate quits.
- [ ] **Step 5: Commit** `feat(app): open tabs from connects, expand inside tabs, confirm terminate on quit`.

### Task 8: Built-in terminal settings UI and live apply

**Files:**
- Modify: `Sources/xpnd/Settings/TerminalSettingsView.swift` (new "Built-in terminal" `Section`)
- Modify: `Sources/xpnd/Terminal/TerminalWorkspace.swift` (`.onChange(of: settings)` → `host.apply`)

**Interfaces:**
- Consumes: `AppSettings.shared.builtInTerminal` (Task 1), `TerminalHost.apply` (Task 4/5).

- [ ] **Step 1: Implement** the section: Picker "Font" over `["System"] + fixed-pitch family names` (`NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask)` mapped to family names, unique, sorted; "System" ↔ `fontName == nil`); Stepper "Size" 9…24 showing the value; Picker "Colours" (System / Light / Dark); Picker "Cursor" (Block / Bar / Underline) and Toggle "Blink"; Stepper "Scrollback lines" 1 000…100 000 step 1 000 with footer "Applies to new sessions." The workspace re-applies settings to every session's host when they change.
- [ ] **Step 2: Build and run** `make run`; with a session open change font, size, colours and cursor → the open session updates at once; scrollback shows the footer.
- [ ] **Step 3: Run** `swift test` — expected: all pass.
- [ ] **Step 4: Commit** `feat(settings): built-in terminal font, colours, cursor and scrollback`.

### Task 9: Docs, changelog, findings

**Files:**
- Modify: `docs/DEVELOPMENT.md` (a "Built-in terminal" paragraph in How it works: `TerminalSessions`, `TerminalHost`/`LiveTerminalHost`, `TerminalWorkspace`, routing via `preferBuiltIn`, `ExpansionTargeting`)
- Modify: `CHANGELOG.md` (Added: built-in terminal tabs; Settings → Terminal → Built-in terminal; "xpnd (built-in)" as the no-terminal choice)
- Modify: `README.md` (Connections section: double-click opens a tab in the built-in terminal; external terminals unchanged)
- Modify: `CLAUDE.md` (Platform findings: whatever SwiftTerm facts were verified the hard way during Tasks 5–8; the dependency note under Rules)

- [ ] **Step 1: Write** the four edits.
- [ ] **Step 2: Run** `make app` — expected: signed `build/xpnd.app`, no new warnings.
- [ ] **Step 3: Commit** `docs: built-in terminal`.
