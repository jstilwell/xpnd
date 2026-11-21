# Review fixes and additions: design

Date: 2026-11-20. Source: a read-only review of the whole app (expansion engine, connections, main window
and settings, snippet editor). The user asked for every finding in that review to be fixed or added.

## Intent

Make expansion reliable for fast typists and slow apps, take friction out of connecting, bring the main window
up to what a Mac app is expected to do, and make snippets easier to write: more variables, a preview, a form
per variable, and highlighting that catches typos before they paste literally.

## Goals, non-goals, anti-goals

**Goals:** every item in the four batches below.

**Non-goals (found by reviewers but not in the agreed list; can be added later):** input-method (IME) awareness
in the key tap, pacing long keystroke-mode typing, debouncing YAML reloads, a picker refocus check, a
connection health probe, structured port forwards, password jump hosts, op `[ERROR]` prefix stripping, caching
the 1Password account id, RDP backoff on wake/network change, `.rdp` file import, usage statistics.

**Anti-goals:**
- Nothing logs, stores or puts in a fixture keystrokes, the typing buffer, snippet text or passwords
  (`CLAUDE.md`). That covers the preview, the replayed keys, recents and undo snapshots (undo lives in memory only).
- No preview or validation runs a script, presses a key, opens an app or runs a Shortcut.
- No rule in `CLAUDE.md` is weakened (argv not shell strings, `CredentialRef.isSafe`, atomic YAML saves, RDP
  password handling, drop folder rules).

## Constraints

- macOS 14+, Swift 6, SwiftPM, Swift Testing; `make test` passes and `make app` builds before each PR.
- One branch and PR per batch, one commit per change, Conventional Commits; `CHANGELOG.md` bullets under a new
  unreleased version, `README.md` and `docs/DEVELOPMENT.md` kept current. No release commit unless asked.
- The key tap is listen-only (`KeyEventTap`): xpnd sees a key after the app gets it and can't swallow it.
- New features need a follow-up PR to `~/code/websites/xpnd.dev` (its `CLAUDE.md` says what to check).

## Approaches (decided)

1. **Strict keywords** — user picked **A: wait for a word boundary**. Alternative B (keep instant firing, fix
   the README) was rejected because "strict" would keep firing inside words (`the` in "then").
2. **Clipboard restore** — restore when the app reads the pasteboard (a promised `.string` on the pasteboard
   item), with today's 150 ms as the floor and 1 s as the cap. A per-app delay list was rejected: it goes stale.
   A clipboard manager that reads every change makes the restore happen at the floor, as today.
3. **Undo** — ⌘Z puts back only what the action removed or moved, into the *current* library (the item at its old
   parent and position, or the end if that parent is gone), registered with the acting window's `undoManager`.
   A whole-library snapshot was considered and rejected by the user: fields save as you type and files reload
   from outside, so restoring a snapshot would silently throw away later edits.
4. **Favourites and recents** — `favorite: true` in the connections YAML (travels with export); recents as a list
   of connection ids in `UserDefaults` (they belong to this Mac).
5. **Variable forms** — a sheet per variable, opened from Insert Variable or by right-clicking a `#{…}` in the
   text. Inline token chips in `NSTextView` were rejected as fragile.

## Batch 1: expansion reliability (`fix/expansion-reliability`)

1. **Strict keywords wait for a word boundary.**
   - A strict snippet fires when a *boundary character* is typed right after its keyword: a space or any
     punctuation/symbol character. Return and Tab still only reset the word (they act in the app before xpnd
     could expand: Return would send a chat message), so they don't fire.
   - On a boundary, the word before it is compared to strict keywords. If a strict keyword equals that word
     and no strict keyword starts with word + the boundary character (so `;sig.` can still be a keyword), it
     fires: delete keyword + boundary, play the expansion, then the boundary character is part of the final
     paste (so it lands right after the text, before keys typed later).
   - A word also starts after an opening character: `(`, `[`, `{`, `<`, `"`, `'`, `` ` ``, so `(;sig ` expands,
     unless a strict keyword continues with that character (so `;(c)` and `don't` keep working). *(Builder's call.)*
   - Where the boundary goes *(builder's call)*: when the expansion ends in text, the boundary and any kept keys
     (item 2) are appended to the text; with `#{cursor}` they go at the end of the text and the left-arrow count
     grows to match, so the caret stays at the cursor. When the expansion ends in a key, shortcut, delay, Open App
     or Run Shortcut, the boundary is deleted and not re-typed (a trailing Enter must not send it), and kept keys
     aren't collected (today's behaviour).
   - Loose snippets and activation strings (connections, folders) keep firing instantly.
   - The editor's "starts another keyword" warning (0.4.0) then applies only when the shorter one is loose or
     an activation string. The README's keyword paragraph says what strict and loose now do.
   - Existing users: strict snippets now need the space. The CHANGELOG says so under **Changed**.
2. **Keys typed during an expansion are kept.** From the match until the backspaces are sent, plain characters
   typed into the target app are collected (cap 64). The delete removes them too, and they are re-typed after
   the expansion as part of the last paste. Any other key (arrow, Return, backspace, a click) in that window
   means the caret moved: collection stops and only what's known is deleted (today's behaviour). Collected
   keys are never logged.
3. **Clipboard captured once per expansion.** `Player` captures the pasteboard before the first paste step and
   restores once after the last, instead of around each paste. Each paste still waits for the app to read
   (item 4). Before a delay, Open App or Run Shortcut step the clipboard is restored, and captured again at the
   next paste, so a Shortcut never reads snippet text and the "someone copied meanwhile" check covers short
   windows only. Keys and keyboard shortcuts between pastes keep the capture. *(Builder's call.)*
4. **Restore after the app reads.** The paste item promises `.string`; when the app requests it, xpnd notes
   the time. Restore happens at max(150 ms after ⌘V, read + a short margin), and no later than 1 s.
   The transient/auto-generated markers and `.currentHostOnly` stay.
5. **Combo limits.** Nesting deeper than 16 levels, or producing more than 10,000 steps, throws a new
   `.comboTooDeep` error before anything on screen changes. A snippet that includes itself (directly or through
   others) throws `.comboCycle(keyword)` instead of pasting the raw `#{combo:…}`.
6. **Shortcuts list fetched once.** `runShortcut` trusts the `check` done before playback. A failed
   `shortcuts list` gets its own message ("Couldn't list your Shortcuts") instead of "No shortcut is named X".
7. **Scripts without +x** get their own message suggesting `chmod +x`, not "No script was found".
8. **Namespace refresh.** When the stores' libraries compare equal to the cached ones, the cached copies are
   replaced with the stores' so later keystrokes hit Array's same-buffer fast path.
9. **Picker results cached.** The picker filters and sorts once per query change, not on each read.

## Batch 2: connections (`feature/connection-improvements`)

1. **RDP password fetch outside the engine's claim.** The 1Password/keychain fetch for an RDP connect runs after
   the exclusive claim ends, as the SSH password phase does, so snippets keep working while Touch ID is up. A
   HUD says "Waiting for 1Password…" (or the provider's name) while it waits.
2. **A second connect no longer cancels a tab's password offer.** Only a clipboard-mode password phase is
   cancelled by the next connect; send-to-tab offers are per tab and live until that tab's own timeout.
3. **SSH defaults.** A Settings → Terminal toggle, "Add a connect timeout and keepalive", on by default (user's
   choice). When on, `-o ConnectTimeout=15 -o ServerAliveInterval=30` are appended after the connection's own
   SSH options (ssh keeps the first value, so per-connection options win). They do override `~/.ssh/config`;
   the toggle's help text says so, and people who set them there turn it off.
4. **Drop-folder cleanup off the main thread**, on `RDPDropFolder`'s serial queue, both on tab close and at launch.
5. **Favourites and recents.** A star toggle in the connection editor and context menu. With an empty query
   the launcher shows Favourites, then Recent (last 5 distinct connects), then the tree; with a query, favourites
   and recents rank above other equal matches. Recents: up to 10 ids in `UserDefaults`, pruned of deleted ids.
6. **Reconnect a failed SSH tab.** A tab that ended with a non-zero status shows **Reconnect** beside Close,
   re-running the connect into the same tab position. Exit 255 reads "ssh couldn't connect (see the message above)".
7. **Import `~/.ssh/config`.** In Import & Export, "Import from SSH Config…" parses `Host` blocks (skips patterns
   with `*`, `?` or `!`), mapping HostName, User, Port, IdentityFile (only if `CredentialRef.isSafe` accepts it),
   and ProxyJump (to a jump host when it names another imported host, else ignored with a note in the preview).
   `Include` and `Match` are ignored and the preview says so. It goes through the existing import preview and
   merge. Never shells out to `ssh -G`.
8. **Missing 1Password item falls back to FreeRDP's prompt.** For `.notFound` and `.noPassword`, the RDP tab opens
   with the password unset (NULL, not empty: `AuthenticateEx` prompts only for NULL) so FreeRDP asks, and the HUD says why. Other errors still stop the connect.
9. **Notes per connection.** Optional `notes` (YAML), a multi-line field in the editor, searched by the launcher filter.
10. **RDP frame copy: investigate.** Check whether `XPRDPView`'s per-frame `CGBitmapContextCreateImage` copies the
    desktop and whether `XPEndPaint` queues unbounded blocks. Change only with evidence (a measurement or the
    documented behaviour); otherwise record the finding in `CLAUDE.md` and leave it.

## Batch 3: main window and settings (`feature/main-window-ux`)

1. **Undo** for deleting, moving and importing snippets, groups, connections and folders ("Undo Delete “X”"),
   restoring only the affected items (see Approaches 3). Undoing an import puts back each item the import
   replaced and removes each one it added.
   The confirmation dialog stays only for deleting a non-empty folder or group.
2. **Keyword and activation fields save on commit** (Return, focus leaving, typing pause), as `CommittingTextField`
   does; the "already used" check still shows while typing.
3. **Snippet context menu:** Duplicate, Enable/Disable, Move to Group ▸, Copy Keyword, Delete. **Group menu:**
   New Snippet, Rename, Enable/Disable, Delete.
4. **Main menu:** File (New Snippet ⌘N, New Snippet Group, New Connection ⌘⇧N only if free, Import…, Export…),
   Edit gets Find ⌘F (focuses the sidebar search), app menu gets About and Hide/Hide Others, Window menu gets
   Minimize ⌘M. Check existing bindings first: ⌘⇧N and others are already taken in terminal tabs.
5. **Status menu** gets "Open Connection Launcher", and both it and "Open Picker" show their global shortcuts.
6. **Folder Details** gets the same button row as other editors: New Connection, Delete.
7. **Picker empty state** ("No snippets match", or a pointer to the main window when there are none), and each
   row shows its group name.
8. **Disabled items:** `.accessibilityValue("Off")` and a tooltip; snippets in a disabled group are dimmed too.
9. **Import Replace** is `.destructive`, Skip is the default button, and the import is undoable (item 1).
10. **First run:** one starter snippet group with `;date` → `#{date}`, the welcome screen shows the real menu bar
    icon and both global shortcuts, and says snippets are added in the main window.
11. **Tooltips** on the icon-only sidebar buttons and one line of help under the RDP options the README explains.

## Batch 4: snippet variables and designer (`feature/snippet-designer`)

**New variables** (argument escapes as today: `\}` and `\\`):

| Variable | Behaviour |
|---|---|
| `#{input:Label=default}` | The form field starts filled with `default`. The first `=` splits. |
| `#{choice:Label:a\|b\|c}` | A pop-up menu in the input form; the first option is preselected. Same label twice shares one field. `\|` isn't supported (documented). |
| `#{longInput:Label}` | A multi-line field in the input form. |
| `#{selection}` | The text selected in the front app (xpnd sends ⌘C, waits up to 300 ms for the pasteboard to change, reads it, restores the clipboard). Only from the picker: from a typed keyword the typing has already replaced any selection, so xpnd sends no ⌘C and it is empty (editors copy the whole line on ⌘C with no selection). The evaluation context is told how the expansion was triggered. *(Builder's call.)* Empty in apps that get keystrokes instead of pastes. |
| `#{uuid}` | A new UUID, uppercase like `uuidgen`. |
| `#{clipboard:trim}`, `:upper`, `:lower` | The clipboard trimmed of surrounding whitespace, or upper/lowercased. Same three for `#{selection:…}`. |
| `#{date:+1d}`, `#{time:+2h}` | The short-style date or time, shifted with the existing shift syntax. |
| `#{fullName}` | `NSFullUserName()`. |

**Preview.** Under the snippet text, a read-only preview of what the snippet will produce, updated as you type
(after a short pause). It runs the real `Evaluator` with a preview context:
- dates, other snippets, `uuid`, `fullName` and transforms are real;
- clipboard, selection, environment variables and script output show as labelled placeholders (`‹clipboard›`),
  so a copied password never appears in the editor;
- each input/choice/longInput is a small field above the preview, prefilled with its default, so you can try values;
- keys, shortcuts, delays, Open App and Run Shortcut show as inline labels (⟨Tab⟩, ⟨⌘⇧J⟩, ⟨wait 500 ms⟩), never run;
- the cursor shows as a marker; an evaluation error shows as the message the HUD would show.

**Variable forms.** Each Insert Variable item opens a sheet with fields for its arguments, and a live sample
where useful: Input (label, default), Choice (label, options list), Long Input (label), Date & Time (format presets,
custom format, shift, sample), Date/Time shift, Key (key picker, count), Keyboard Shortcut (`ShortcutRecorder`),
Other Snippet (searchable list of keywords, plain/upper/lower), Delay (stepper), Script (file picker, timeout),
Clipboard/Selection (transform). Variables with no arguments insert directly. Right-clicking inside a `#{…}` in
the text offers "Edit Variable…", which opens the same sheet filled in and replaces that variable.

**Highlighting and checks.** The text view colours well-formed variables and gives a red underline and tooltip to
`#{…}` that won't expand: an unknown name, a bad argument (`#{key:tabb}`, `#{dateTime:+1x:…}`, `#{delay:abc}`),
a missing or self-including snippet. The check is a pure function shared with the preview, split out of
`Evaluator.resolve` so the two can't disagree.

**New Snippet from Clipboard** in the status menu: opens the main window with a new snippet whose text is the
clipboard's string (refused, with a HUD, when the clipboard item is concealed).

## Left to the builder

File layout, type names, the exact HUD wording, colours, sheet layouts, debounce durations other than those
given, test structure, and how each batch's commits are split, within the rules above.
