# Built-in terminal — design

2026-11-03. Project 3 of xpnd: SSH sessions inside the main window.

## Intent

xpnd already launches SSH into an external terminal. The user wants the main window to be the place
they work from, RoyalTSX-style: double-click a connection and the session opens on the right, in a
tab, with the font and colours they chose. The emulator is **SwiftTerm**, chosen over libghostty
because today only libghostty's parser is public; its renderer and view are Ghostty.app's internal,
untagged API that would need a Zig toolchain and macOS 15.6. The terminal sits behind one view, so a
later swap is contained. In the UI it is the "built-in terminal", never "Ghostty".

## Goals

- Double-clicking a connection in the sidebar (or Connect in its menu) opens an SSH session in a
  terminal filling the right side of the window. Each session is a tab.
- Tabs: titled with the connection's name, in its colour; right-click offers Duplicate (a new session
  to the same connection) and Close.
- The terminal uses the font, size, colours, cursor and scrollback from Settings → Terminal → Built-in
  terminal, applied live to open sessions.
- Editing while sessions are open: a single click on a sidebar item opens its editor as a panel over
  the tabs with a visible Close button (Esc closes too). With no sessions, the right side is the
  editor exactly as today.
- Routing of a typed activation string: inside an external terminal, today's behaviour (typed into
  it); inside an xpnd terminal tab, a new tab; anywhere else, the default from Terminal settings,
  where "xpnd (built-in)" is a new choice.
- Session end: a clean exit (status 0) closes the tab; with no tabs left the right side returns to
  the editor. An error exit keeps the tab with its output and a "Session ended" bar with a Close
  button, so a refused key or unreachable host can be read.
- Closing the window or quitting with live sessions asks "Terminate N sessions?" (Terminate /
  Cancel). Ended sessions don't count.
- Credentials keep today's model: passwords copied concealed, cleared after 30 s, pasted by the user
  at the prompt; sudo cascade and ⌘-for-sudo unchanged. xpnd never writes a secret to the PTY.
- Snippets expand inside an xpnd terminal tab like in any other app.

## Non-goals (this round)

- A local-shell tab, split panes, a Reconnect button, tab reordering, a Ghostty config reader.
- VNC and RDP in tabs (RDP is Project 4).
- Detecting prompts to auto-type passwords.
- Persisting sessions across quits, or scrollback anywhere on disk.

## Anti-goals

- Terminal output, scrollback, or anything typed in a session reaching the log, a file, or a test
  fixture. The existing rule holds: never log keystrokes, buffer, snippet text, or secrets.
- `ssh` launched through a shell. It runs as argv, like every other process xpnd starts.
- A regression for users who keep an external terminal as their default: nothing in their flow changes
  unless they double-click in the window.

## Constraints

- macOS 14+, Swift 6 language mode, SwiftPM. Dependency pinned exactly:
  `https://github.com/migueldeicaza/SwiftTerm` at `1.99.2` (the 2.0 API; released 2026-10-29; MIT;
  canonical repository under migueldeicaza — verify the URL character for character). It needs
  swift-tools 6.2, which Xcode 27 provides. Add nothing else directly. Accepted by the user: SwiftTerm's
  transitive packages (`swift-argument-parser`, `swift-docc-plugin`, `swift-png`; used only by its CLI
  tool and non-Apple builds) get pinned in `Package.resolved`, and its `SwiftTermBuildInfoPlugin`
  build-tool plugin runs on every build. Note both in the PR.
- The event tap currently resets on any key aimed at xpnd's own process (`targetsXpnd`), so no
  expansion happens in xpnd's windows. Keys aimed at a focused terminal tab must be exempt.
- `ExpansionEngine` runs one action at a time; opening a tab stays inside that claim like a launch.
- `make app` signs with Developer ID; SwiftTerm is a static Swift library, so nothing new goes in
  `Contents/Frameworks`.

## Decided by the user

- SwiftTerm, not libghostty.
- Double-click / Connect in the window → built-in tab, always.
- Tabs with Duplicate on right-click.
- Editor as an overlay above the tabs with an easy close.
- Routing as in Goals.
- Clean exit closes the tab; error exit keeps it until closed.
- Closing the app with live sessions asks before terminating.

## My calls (the user can override)

- Both window close and Quit ask; the alert is the same.
- "xpnd (built-in)" is selectable as the default for the no-terminal case; the launcher hotkey and
  typed strings follow routing, only in-window actions force a tab.
- Settings: font family (fixed-pitch families only) and size, colour scheme (follow system / light /
  dark using SwiftTerm's default palettes), cursor style (block / bar / underline, blink on/off),
  scrollback lines (default 10 000). Defaults: the system monospaced font at 13 pt, follow system,
  block cursor blinking, 10 000 lines.
- Keyboard: ⌘W closes the selected tab (asks if live), ⌘⇧] / ⌘⇧[ move between tabs, ⌘1–⌘9 pick a tab.
  These exist only while the terminal workspace is showing. ⌘T is not taken (no local shell).
- Snippets as well as activations work in a tab; the paste lands in the terminal through its normal
  paste path.
- Duplicate runs the full connect for the tab's connection (`connectExclusively` with `forceBuiltIn`:
  engine claim, key fetch, password copied again, sudo cascade), not a re-run of the saved argv — a
  password login would otherwise get a prompt with nothing left to paste. It lives beside the other
  connects in `AppDelegate+Connections`, so `TerminalSessions` only knows `open` and `close`.
- The session's environment is the user's plus `TERM=xterm-256color`, and `LANG` from the system
  locale when the environment has none (GUI apps inherit no locale; Terminal.app does the same), so
  the remote shell isn't left in the C locale.
- An ended-with-error tab shows "Session ended (exit N)" or the signal name; its terminal is read-only.
- The overlay editor is a card with the existing `DetailsPane` inside, a Close button top-right, Esc
  closes, and closing returns keyboard focus to the selected tab's terminal. Selecting a different
  sidebar item while the overlay is open just changes its contents.

## How it fits the code

- **`LaunchPlan`** gains `.builtInTab(SSHCommand)`. `LaunchPlanner.plan` takes one more input,
  `inBuiltInTerminal: Bool` (the front app is xpnd and the main window's first responder is a
  terminal view). Order: `inBuiltInTerminal` → `.builtInTab`; front app in `terminalBundleIDs` →
  `.typeIntoFrontTerminal`; otherwise `whenNoTerminal`, where `TerminalPreset.builtIn` → `.builtInTab`.
  `builtIn` has no bundle id for detection and `supportsTabs` is irrelevant to it; keep it out of the
  detected-terminals list in Settings.
- **`ConnectionService.connect`** executes `.builtInTab` through a new injected closure
  `openTab: @MainActor (SSHCommand, Connection) -> Void` instead of `LaunchExecutor`; the delete of
  typed characters and the password phase run exactly as for a launch. `AppDelegate` wires
  `openTab` to the main window, showing it if hidden. A window action (double-click, Connect) calls
  `connectExclusively` with a flag that forces `.builtInTab`; simplest is a `forceBuiltIn` parameter
  threaded to `plan`.
- **Session model** (`Sources/xpnd/Terminal/`): `TerminalSession` (`id`, `connectionID`, `name`,
  `color`, `state: .running | .ended(status)`, and the owned SwiftTerm view) and `TerminalSessions`
  (`@Observable`: `sessions`, `selected`, `open(command, connection)`, `duplicate(id)`,
  `close(id)`, `liveCount`). The view is created with the session so its state survives tab
  switches; the process runs `/usr/bin/ssh` with `SSHCommand.arguments.dropFirst()` (the first
  entry is `ssh`) and the user's environment plus `TERM=xterm-256color`. Process exit arrives through
  SwiftTerm's delegate and updates `state`; status 0 removes the session and selects its neighbour.
- **`MainView`**: the detail column shows `DetailsPane` when `sessions.isEmpty`, else
  `TerminalWorkspace` (tab bar + the selected session's `NSViewRepresentable`) with the editor
  overlay driven by `model.editorShown`. A single click sets `selection` and, when sessions exist,
  `editorShown = true`; the sidebar's double-click opens a tab and leaves the overlay alone.
- **Expansion in tabs**: `AppDelegate` passes `targetsXpnd && !mainWindow.terminalHasFocus` to
  `engine.handle`, where `terminalHasFocus` checks the key window's first responder. Nothing else in
  the engine changes; the front-app guard already holds since xpnd is in front.
- **Close and quit**: `MainWindowController.windowShouldClose` and a new
  `applicationShouldTerminate` in `AppDelegate` both ask when `liveCount > 0`; Terminate kills every
  session's process (SIGHUP via the PTY close) before proceeding.
- **Settings**: `BuiltInTerminalSettings: Codable` stored in `AppSettings` (same pattern as
  `TerminalSettings`); `TerminalSettingsView` gets a "Built-in terminal" section; the no-terminal
  picker gets "xpnd (built-in)". Open sessions observe the settings and re-apply font, colours,
  cursor and scrollback.

## Tests

- `LaunchPlanner`: `inBuiltInTerminal` wins over a front terminal; `.preset(.builtIn)` yields
  `.builtInTab`; an external front terminal still yields `.typeIntoFrontTerminal`; `forceBuiltIn`.
- `TerminalSessions` with an injected process factory (never SwiftTerm): open selects the new
  session, close, exit 0 removes and selects the neighbour, exit ≠ 0 keeps with `.ended`,
  `liveCount` ignores ended sessions.
- `BuiltInTerminalSettings`: defaults and round-trip through JSON.
- Existing suites stay green. UI behaviour (overlay, tab bar, shortcuts, alerts, live settings) goes
  in the PR's manual checklist.

## Left to the builder

- SwiftTerm 2.0 API specifics: the macOS view type, delegate for process exit, how fonts, palette,
  cursor style and scrollback are set, and the read-only mode for an ended tab.
- The exact first-responder check for "terminal has focus".
- Tab bar and overlay visuals, the alert wording beyond "Terminate N sessions?".
- Where the font family picker gets its list (fixed-pitch families from `NSFontManager`).
- Minimum width of the detail column so a terminal is usable.
- Docs: `docs/DEVELOPMENT.md` (new component paragraph), `CLAUDE.md` (findings as they're verified),
  `CHANGELOG.md`, and the README's Connections section.
