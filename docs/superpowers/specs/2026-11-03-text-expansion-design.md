# xpnd — Text Expansion (Project 1 of 3) — Design

## Intent

A native macOS app, written in Swift, that brings Beeftext's text expansion
(https://github.com/xmichelo/Beeftext) to the Mac. The user uses Raycast
snippets today and finds them too basic. What they want from Beeftext is its
variables, its templates that ask for values when they fire, and easy
export/import (in YAML).

xpnd will grow into a sysadmin tool, built in this order:

1. **Text expansion** (this document)
2. **Connection manager**: a hotkey popup, like Raycast's launcher, listing
   saved servers in a folder tree (dev/prod by default). It opens SSH in the
   user's chosen terminal or multiplexer (Ghostty, Herdr, etc.) and VNC
   through macOS Screen Sharing. Credentials come from 1Password and cascade:
   global, then environment, then server. SSH keys stay in 1Password and are
   used through its SSH agent. It gets its own design document.
3. **Bundled RDP**: Windows desktops open inside the app the way RoyalTSX
   does it, by building FreeRDP into the app. It gets its own design document.

This document covers only project 1. The app shell it creates must leave room
for 2 and 3: a second global hotkey and more sections in Settings.

## Goals

- Typing a keyword in any app replaces it with the snippet's text.
- Beeftext's variables, adapted to macOS (list below).
- `#{input:...}` prompts appear when a snippet fires, and the values typed into
  them go into the inserted text.
- A picker, opened by its own global hotkey, to search snippets and insert one.
- Groups of snippets, each of which can be turned on or off.
- Import and export as YAML.
- Keywords that open an app or run a macOS Shortcut, as well as insert text.

## Non-goals (for this project)

- Anything for connections, credentials, or 1Password; those are project 2.
- Sync between machines, and a configurable store location.
- Importing from Raycast, Beeftext, or any other app. The user is starting
  from scratch, and YAML is the only format.
- Rich text snippets: plain text only for v1. (My call; Beeftext supports rich
  text, but the user didn't ask for it.)
- The Mac App Store. Watching keystrokes system-wide needs a non-sandboxed app.

## Anti-goals

- It must not be flaky. A missed or half-done expansion (keyword deleted, text
  never pasted) or a clobbered clipboard is worse than no expansion.
- It must not leak what the user types. Keystrokes are never logged or stored
  beyond the small rolling buffer used for matching. The only network traffic
  is Sparkle's update check against GitHub releases, which can be turned off
  in Settings.
- Importing someone else's YAML must not quietly give them a way to run
  scripts on this Mac (see "Shell variable" below).

## Behavior

### Matching (taken from Beeftext)

- The app keeps a buffer of printable characters typed since the last reset.
- **Strict** (the default for each snippet): the buffer must equal the
  keyword exactly.
- **Loose** (per snippet): the buffer only has to end with the keyword.
- Backspace removes the last character from the buffer.
- Space, Return, Tab, Escape, arrow keys, other non-printable keys, a mouse
  click, and a change of the frontmost app all clear the buffer. Modifier keys
  on their own do not.
- Keywords are case-sensitive. (My call, matching Beeftext's default.)
- Nothing expands while macOS Secure Input is on (password fields). That's
  enforced by the OS anyway; the app should simply not misbehave then.

### Substitution

Like Beeftext: delete the keyword with backspaces, put the expanded text on
the clipboard, send Cmd+V, then restore the user's previous clipboard
contents. The clipboard save and restore must cover every pasteboard type,
not only plain text. `#{cursor}` moves the caret back with left-arrow presses
after the paste. `#{key:}`, `#{shortcut:}` and `#{delay:}` split the output
into segments that are pasted and played in order.

**Order and failure (my call):** expansion has two phases.

1. **Evaluate.** Every value-producing variable is computed before anything
   on screen changes: clipboard, date, envVar, `#{combo:}`, `#{shell:}`, and
   the input form. If any of them fails (a script times out or exits
   non-zero, a `#{combo:}` keyword is missing, the form is cancelled), the
   whole expansion is abandoned. The keyword stays where it is and a brief
   notification says why.
2. **Play.** The keyword is deleted, and then segments and actions run in
   the order they're written. `#{openApp:}` and `#{runShortcut:}` split
   segments like `#{key:}` does, so `#{openApp:X}#{delay:500}hello` types
   into the app it just opened. `#{runShortcut:}` waits for the Shortcut to
   finish, with a 30s timeout. If an action fails in this phase, playback
   stops there and a notification says so, since what's already done can't
   be undone.

### Variables

Same `#{...}` syntax and escaping as Beeftext: names are case-sensitive, no
spaces inside the braces, unknown variables are left untouched, and `\}` and
`\\` are escapes.

| Variable | Behavior |
|---|---|
| `#{clipboard}` | Clipboard text (plain) |
| `#{date}` `#{time}` `#{dateTime}` | Current date/time, system locale format |
| `#{dateTime:<format>}` | Custom format. Uses Unicode/`DateFormatter` patterns, not Qt's (My call: the Mac-native choice) |
| `#{dateTime:<shift>:<format>}` | Shift units `y M w d h m s`, signed (e.g. `+1d-2h`); format optional, colon required |
| `#{combo:<keyword>}` | Another snippet's expanded text; cycles are not expanded |
| `#{upper:<keyword>}` `#{lower:<keyword>}` | Same, case-converted |
| `#{cursor}` | Caret ends up here; only the first one counts |
| `#{input:<label>}` | Asks for a value (see below) |
| `#{envVar:<name>}` | Environment variable of the app process |
| `#{shell:<path>[:<timeoutMs>]}` | Runs the script at that path and inserts its stdout. Default timeout 10s; `0` means no timeout. Replaces Beeftext's `#{powershell:}` |
| `#{key:<name>[:<count>]}` | Presses a key: tab, enter, space, delete, forwardDelete, home, end, pageUp, pageDown, up, down, left, right, escape, f1–f20 |
| `#{shortcut:<keys>}` | Sends a shortcut, e.g. `Cmd+Shift+J` (names: Cmd, Option, Control, Shift) |
| `#{delay:<ms>}` | Pauses |
| `#{openApp:<path>}` | Launches (or brings forward) the app at that path, e.g. `/System/Applications/Calculator.app`, via `NSWorkspace`. Inserts nothing |
| `#{runShortcut:<name>}` | Runs the named shortcut from the macOS Shortcuts app (`/usr/bin/shortcuts run <name>`, with the name passed as an argument, never through a shell). Inserts nothing |

### Action snippets (keyword → app or Shortcut)

Requested by the user: typing `;calc` should be able to open Calculator or
start a macOS Shortcut, and users should be able to point a keyword at any
app by browsing for it or giving a path. Rather than a separate feature, these
are the two action variables above. A snippet whose text is only
`#{openApp:/System/Applications/Calculator.app}` deletes the typed keyword and
opens Calculator. Because they're variables, they also mix with text and work
from the picker. (Doing this as variables is my call.) In the editor's "Insert
Variable" menu, "Open App…" shows a file browser filtered to `.app` bundles,
and "Run Shortcut…" lists the user's shortcuts (`shortcuts list`). Each one
inserts the variable for whatever the user picks. If the app path doesn't
exist or the shortcut fails, the app shows a brief notification; it doesn't
fail silently.

### Input prompts ("templates that pop up")

When a snippet (including any nested via `#{combo:}`) contains
`#{input:...}`, the app shows one small floating form near the frontmost
window, with one field per distinct label. Repeated labels share one field.
Enter submits and Escape cancels. Cancelling inserts nothing and leaves the
typed keyword where it is. After the form closes, focus returns to the
original app before pasting. (A single form is my call; Beeftext shows one
box per variable.)

### Shell variable safety

`#{shell:}` takes only a path to a script, never inline code. On import, if
any incoming snippet contains `#{shell:}`, `#{runShortcut:}`, `#{openApp:}` or
`#{shortcut:}` (keys sent to the front app can open Terminal and type a
command), the import screen lists those snippets and what they would run, and
asks for confirmation before importing them. (My call.)

### Picker

A global hotkey (default Ctrl+Option+Cmd+Space; my call, can be changed in
Settings) opens a small, centered, Raycast-style search panel. Typing filters
snippets by keyword, name, and text, arrow keys move the highlight, Enter
inserts the snippet into the app that was frontmost (variables and prompts
apply), and Escape closes it. The connection manager will get its own,
separate hotkey in project 2.

### Snippets, groups, editor

- A snippet has: name, keyword, text, matching mode (strict/loose), enabled,
  and group.
- A group has: name, description, and enabled. Turning a group off turns off
  all its snippets.
- The Settings window has a Snippets section: groups list, snippets list,
  search, and an editor with an "Insert Variable" menu. Other sections:
  General (launch at login, global on/off, picker hotkey) and Import/Export.
- The menu bar icon's menu has: enable/disable expansion, open picker, open
  Settings, quit. No Dock icon.

### Storage and YAML

- The app's own store is a YAML file at
  `~/Library/Application Support/xpnd/snippets.yaml`, in the same schema as
  export, so the user can hand-edit or version it. (My call.) Writes are
  atomic (write to a temp file, then rename).
- If the file fails to parse at launch, the app keeps it untouched, shows the
  error, and starts with expansion off. It never overwrites a file it couldn't
  read.
- The app watches the file and reloads it when it changes on disk. Edits made
  in the app save at once, so there's never unsaved in-app state for a reload
  to fight with. Saving from the app rewrites the file and drops YAML comments
  and custom formatting. The editor's help text says so. (My calls.)
- Hand edits to this file are trusted like the user's own shell config, so
  the import confirmation for `#{shell:}`/`#{openApp:}`/`#{runShortcut:}`/`#{shortcut:}`
  applies to imports only, not to reloads. (My call.)
- Keywords are unique across all snippets, including disabled ones, so two
  snippets can't share a keyword even in different groups. The editor refuses
  a duplicate.
- On import, a group whose name already exists is merged into it, and a
  group with a new name is created. When a keyword conflicts, "skip" keeps the
  existing snippet. "Replace" removes it and adds the incoming one to the
  incoming group. (My calls.)
- When keywords overlap (e.g. a loose `sig` and a strict `;sig`), the longest
  matching keyword wins.
- Export writes all snippets, or the selected groups, to a YAML file the user
  picks.
- Import reads a YAML file. When a keyword already exists, the user picks
  "skip" or "replace" for the whole import.
- Schema (version field so it can evolve):

```yaml
version: 1
groups:
  - name: Work
    description: Ticket boilerplate
    enabled: true
    snippets:
      - name: Ticket reply
        keyword: ";tix"
        matching: strict        # strict | loose
        enabled: true
        text: |
          Hi #{input:Name},
          Ticket #{input:Ticket #} is resolved as of #{dateTime:yyyy-MM-dd}.
          #{cursor}
```

## Constraints

- Swift, SwiftUI for windows and settings, with AppKit where needed (the menu
  bar item, floating panels, event tap).
- macOS 14 minimum, matching HoverEnhance.
- **Released publicly as free, open source software** by the user, who is an
  Apple developer. Build, signing, and release follow the user's existing app
  the HoverEnhance repository (read its `Makefile`,
  `bin/build-release.sh`, `bin/run.sh`, `docs/DEVELOPMENT.md`, and
  `CLAUDE.md`). In short:
  - A SwiftPM executable target, bundled into `build/xpnd.app` by a
    `Makefile` (`make app/run/test/log/release`), using `xcrun swift`.
  - Signed with the first Apple Development / Developer ID identity, so the
    Accessibility grant survives rebuilds.
  - Releases are universal, use Developer ID with the hardened runtime, and
    are signed by team `G65RD22S57`. They ship as a notarized, stapled DMG.
  - Sparkle updates use a signed appcast attached to the latest GitHub
    release (`jstilwell/xpnd`).
  - The bundle ID follows the pattern `com.jessestilwell.xpnd`.
  - MIT license, copyright Stilwe LLC.
  - README, CHANGELOG, and `docs/DEVELOPMENT.md` follow HoverEnhance's
    conventions.
- Reuse what HoverEnhance already solved and adapt it, without inventing a
  new approach. Copy and adapt:
  - `GlobalShortcut.swift` (Carbon hotkeys and recording a shortcut in
    Settings)
  - `AccessibilityPermission.swift` and the welcome window that guides the
    user through granting access
  - its Sparkle wiring
  - its unified-log setup
- Non-sandboxed, so the user must grant Accessibility permission (and Input
  Monitoring, if the OS asks for it). First launch walks the user through
  granting it and detects when it has been granted.
- Pin every dependency to an exact version and check the package name for
  typosquats. Expected: Sparkle (as in HoverEnhance) and a YAML library
  (Yams, `github.com/jpsim/Yams`).
- The project folder `xpnd` is empty and not yet a git
  repo. Xcode 27.2 and Swift 6.4 are installed.

## Tests the builder should include

- Matcher: strict/loose, buffer resets, backspace.
- Variable parser and evaluator: every variable, escapes, unknown variables,
  `#{combo:}` cycles, date shifts.
- YAML: export/import round-trip, the conflict choice, a malformed file, and
  detection of `#{shell:}`, `#{runShortcut:}`, `#{openApp:}` and `#{shortcut:}` on import.
- Action variables: a missing app path and an unknown shortcut name each
  produce an error, not a crash or silent no-op.

## Left to the builder

- Module boundaries within the SwiftPM layout.
- Exact event-tap implementation and timing between backspaces, paste, and
  clipboard restore.
- Settings window look and layout, following macOS conventions.
- App icon and menu bar glyph.
