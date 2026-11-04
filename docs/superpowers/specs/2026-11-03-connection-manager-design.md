# xpnd — Connection Manager (Project 2) — Design

## Intent

xpnd already expands typed keywords into text. Project 2 adds what the user
uses RoyalTSX for today: a saved tree of servers, opened in a keystroke,
with credentials from 1Password. The user wants:

- to type `;aws` anywhere and be connected to that server;
- to type `;prod` to see a numbered list of the servers in that folder and
  press `1` to connect;
- credentials that cascade: global, then folder, then server. Most servers
  share credentials, and the user is tired of setting them per connection.

1Password is the primary credential source. Bitwarden is an option for people
who won't use 1Password. It follows once 1Password works end to end, but the
code must leave room for it.

xpnd becomes a Dock app with a main window: a sidebar tree of connections and
snippets on the left, details on the right. Later projects will open
sessions as tabs on the right: an embedded Ghostty terminal (project 3) and
bundled RDP (project 4). Leave room for them; don't build them.

Prior design: `docs/superpowers/specs/2026-11-03-text-expansion-design.md`.
Its constraints (build, signing, privacy, file safety) still apply.

## Goals

1. xpnd shows a Dock icon and a main window, and keeps running in the menu
   bar when the window closes.
2. The main window's sidebar has two sections, **Connections** and
   **Snippets**, each a folder tree. The right pane shows the selected
   item's details for editing.
3. Connections: SSH and VNC, each with name, host, port, an optional
   username override, an optional activation string, an optional credential
   override, and an **Advanced** section (jump host, extra SSH options,
   auto-sudo).
4. Activation strings: typing a connection's string (`;aws`) connects;
   typing a folder's string (`;prod`) opens a numbered quick menu.
5. Connecting opens SSH in a terminal. If a terminal is in front, the command
   is typed into it. Otherwise a configurable launch method runs. VNC opens in
   macOS Screen Sharing.
6. Credentials link to 1Password items through a search UI, and are resolved
   along the cascade at connect time. Secrets are never stored by xpnd.
7. A "credential provider" boundary, so Bitwarden can be added without
   touching callers.
8. Empty **dev** and **prod** folders on first launch.
9. A **connection launcher** on its own global hotkey, separate from the
   snippet picker's. It's a searchable, Raycast-style popup over all saved
   connections, as the user first asked for. Both hotkeys are set in
   Settings → General.

## Non-goals (this project)

- Embedded terminal (Ghostty / libghostty) and RDP. Those are later projects,
  but the window must have room for session tabs.
- Bitwarden support itself, beyond the provider boundary.
- Importing from RoyalTSX or any other app. The user will recreate
  connections by hand.
- xpnd typing passwords into terminals. Passwords are copied, never typed
  (see Credentials), until the embedded terminal can see real prompts.
- Sync, sharing, or teams.

## Anti-goals

- **Never connect to, or type into, the wrong place.** A command typed into
  the wrong window, or a password pasted where it doesn't belong, is worse
  than doing nothing. The text-expansion engine's "the app you typed in is
  still in front" guard applies to every connection action.
- **No secrets on disk, in logs, or in clipboard history.** xpnd's files hold
  only 1Password references. Copied passwords are marked so clipboard
  managers skip them, and are cleared after 30 s. Nothing secret is ever
  logged.
- **Snippets must not get worse.** Moving snippet editing into the main
  window and sharing the keyword namespace must not regress any behavior
  from project 1.

## The app shell

- xpnd becomes a regular app: `LSUIElement` false, Dock icon.
- **My call:** the Dock icon shows while the main window is open. When the
  last window closes, xpnd switches back to menu-bar-only (`.accessory`
  activation policy) and keeps running. Clicking the Dock icon or choosing
  "Open xpnd" in the menu bar reopens the window. Launch at login starts
  menu-bar-only.
- The menu bar menu gains "Open xpnd…" and keeps its existing items.
- **Main window (layout A, chosen by the user):**
  - **Sidebar:** a "Connections" section and a "Snippets" section, each an
    outline of folders and items.
  - **Right pane:** a tab strip. The first tab is always **Details**, the
    editor for whatever is selected. Later projects add session tabs here.
- **Snippet editing moves** from Settings into the main window's Snippets
  section, reusing the existing snippet editor views (`SnippetEditorView`,
  `TemplateTextView`, keyword validation). It behaves exactly as today:
  saves at once, the read-only state while the file has an error, and the
  Insert Variable menu.
- **Settings keeps only preferences:**
  - General (existing)
  - **Terminal** (new; see Launching)
  - **Password manager** (new; see Credentials)
  - Import/Export (existing, extended to connections)

## Connections model

- A **folder** has: name, activation string, an optional credential, and
  children (folders and connections). Folders nest.
- A folder's activation string defaults to `;` + its name, lowercased with
  spaces removed (`dev` becomes `;dev`). You can change it from the folder's
  right-click menu or its Details pane. (My calls:)
  - In YAML, an **absent** `activation` means "derived from the name". A
    derived string follows renames. A written value is custom and stays put.
    `""` means none.
  - If the derived string is already taken (a snippet keyword, or another
    folder with the same name elsewhere in the tree), that folder has no
    activation, and its Details pane says why and offers to set one. This
    also covers the first-launch dev/prod folders when the user already has
    a `;dev` or `;prod` snippet.
- A **connection** has:
  - **name**
  - **type:** `ssh` or `vnc`, with `rdp` reserved for later
  - **host** and **port** (default 22 for SSH, 5900 for VNC)
  - **username:** an optional override. Otherwise it comes from the
    resolved credential.
  - **activation string:** optional, no default
  - **credential:** an optional override
  - **Advanced** (SSH only):
    - **Jump host:** either another saved SSH connection, picked from the
      tree, or free text (`user@host:port`). Becomes `ssh -J`.
    - **Extra SSH options:** free text, appended as written. It is split
      into arguments with shell-style quoting rules; it is never run
      through a shell.
    - **Auto-sudo:** a tick box.
- **Sudo credential** is its own cascading slot, alongside the login
  credential (my call): connection, then nearest folder, then global, then
  the login credential if that item has a password. Fifty servers that log in
  with an SSH key can share one sudo password set on their folder. If nothing
  in the chain has a password, connecting with auto-sudo still works, and the
  HUD says "No sudo password set for aws-external-web-services".
- Every folder and connection has a persisted ID, so jump-host references
  survive renames.

### Storage

- A new file at `~/Library/Application Support/xpnd/connections.yaml`, with
  the same guarantees as `snippets.yaml`:
  - atomic saves
  - never overwrite a file that couldn't be read or parsed
  - watch the file and reload on external edits
  - check the disk before every in-app save
  - recover when the file is deleted
- Reuse the existing `SnippetStore` machinery: generalize it, or share its
  file-safety core. The builder chooses how, but there must be one
  implementation of the file-safety rules, not two copies.
- Schema (versioned, IDs persisted, no secrets):

```yaml
version: 1
credential:            # global login credential, optional
  provider: 1password
  account: <account id>
  vault: <vault id>
  item: <item id>
  title: "Default SSH"     # non-secret details, captured when picked
  category: ssh_key        # ssh_key | login | password | server
  username: ubuntu         # from the item, if it has one
sudoCredential: { … }      # global sudo credential, optional
folders:
  - id: 7f1c…
    name: prod
    # no activation key: derived from the name (;prod)
    credential: { provider: 1password, account: …, vault: …, item: …, title: "prod-ssh" }
    connections:
      - id: 3a9e…
        name: aws-external-web-services
        type: ssh
        host: 54.242.245.93
        port: 22
        activation: ";aws"
        advanced:
          jumpHost: { connection: 91bd… }     # or { text: "ec2-user@bastion:22" }
          sshOptions: "-o ServerAliveInterval=30"
          autoSudo: true
    folders: []
  - id: 0c44…
    name: dev
    connections: []
    folders: []
```

- **Import/Export:** connections export and import as YAML the same way
  snippets do: whole file or selected folders, merge by folder name,
  skip/replace on activation-string conflicts. Folder IDs are kept unless
  they collide. Credential references are exported as written; they only
  work for someone with access to the same 1Password items. Import shows the
  hosts being added, so nothing arrives silently.

## Activation strings and the quick menu

- **Each file gates only its own entries (my call).**
  - A broken `connections.yaml` pauses activation strings. A broken
    `snippets.yaml` pauses snippets. Neither stops the other.
  - Uniqueness checks use the other file's last good contents, so either
    file can still be edited while the other has an error.
  - If hand edits create a duplicate across the two files, that string
    triggers nothing until it's resolved. Both editors flag it, and the HUD
    says so once.
- **Snippet groups stay flat (my call).** In the sidebar they appear as
  one-level folders, with their on/off switches and descriptions.
  `snippets.yaml` keeps version 1, and nothing about snippet storage or
  import changes.

- **One namespace (the user agreed):** activation strings and snippet
  keywords share it. Uniqueness is enforced across both files, in both
  editors, with the existing `keywordProblem` messages extended to name the
  owner ("“;dev” is already used by folder “dev”"). The same length and
  no-whitespace rules apply.
- Activation strings match like strict snippets: the whole typed buffer since
  the last reset must equal the string. They go through the existing
  `ExpansionEngine` (buffer, matcher, "targets xpnd" skip, front-app guard,
  one expansion at a time). A match runs a **connection action** instead of
  pasting text. The builder decides how to represent that, as long as one
  engine handles both.
- **Connection string typed:** xpnd deletes the typed string, then connects
  (see Launching), relative to the app the string was typed in.
- **Folder string typed:** xpnd deletes the typed string and opens the
  **quick menu**:
  - A small panel near the screen center, in the same style as the picker:
    non-activating, closes on losing focus or on Esc.
  - It lists the folder's connections, then its subfolders, each numbered
    1–9. A subfolder row opens that folder's list in the same panel, and ←
    goes back.
  - Pressing a digit picks that row. ↑/↓ and Return also work. Items past 9
    are reachable with the arrow keys only.
  - Each row shows its type (ssh/vnc) and, after picking, connects relative
    to the app that was in front when the string was typed.
  - An empty folder shows "No connections in prod yet" and an
    "Open xpnd" button.
- Connections without an activation string are still reachable from their
  folder's quick menu, the connection launcher, and the main window
  (double-click or Connect).

## Connection launcher (global hotkey)

- **Hotkey:** default Control-Option-Command-C (my call). The snippet picker
  keeps Control-Option-Command-Space. Settings → General shows both
  shortcuts with the existing recorder, labelled "Snippet picker" and
  "Connection launcher". Changing either re-registers it at once, with the
  existing "in use by another app" message on conflict.
- **Panel:** the same kind as the snippet picker: centered, non-activating,
  key-capable, and it closes on losing focus or on Esc.
  - **Empty search:** shows the tree as an indented, expandable list of
    folders and connections, in sidebar order.
  - **Typing:** filters across all connections by name, host, activation
    string, and folder path (case- and diacritic-insensitive). Results are a
    flat list showing each connection's folder path (`prod › aws`).
  - **Ranking:** a name prefix comes first, then a name, string or host
    match, then a folder-path match.
- **Keys:** ↑/↓ move, Return connects, → and ← expand and collapse in tree
  mode. Connecting follows the same rules as an activation string, relative
  to the app that was in front when the hotkey was pressed, including the
  front-app guard.
- **Code:** reuse the snippet picker's panel and refocus code rather than
  copying it. A shared base or helper is the builder's call.

## Launching

### Terminal detection

- **"A terminal is in front"** means the frontmost app's bundle ID is on an
  editable list in Settings → Terminal. The default list is Terminal,
  iTerm2, Ghostty, and Warp; the builder verifies the bundle IDs.

### SSH when a terminal is in front

- xpnd types the connect command and presses Return into the focused
  window, using the existing Player (paste, then the Return key). This lands
  in whatever has focus, including a Herdr or tmux pane. That's intended.

### SSH when no terminal is in front

- Settings → Terminal → "When no terminal is in front" offers:
  1. **Open in a preset app:** Terminal, iTerm2, Ghostty, or Warp, with
     "new window" or "new tab" where the app supports tabs.
     - Terminal and iTerm2 use AppleScript. This needs the Apple Events
       entitlement under the hardened runtime and an
       `NSAppleEventsUsageDescription`. The first use shows macOS's
       Automation prompt.
     - Ghostty uses `open -na Ghostty.app --args -e <command>`, or whatever
       Ghostty supports for running a command.
     - **Builder:** verify each preset can run a command reliably on
       current versions. Drop a preset that can't, and say so in its place
       in Settings, pointing to the custom command.
  2. **Run a custom command:** a template containing `{command}`, run with
     `/bin/sh -c`. The template is the user's own setting, so it's trusted.
     `{command}` is substituted shell-quoted. This covers opening a pane in a
     running Herdr or tmux session, or any terminal not on the list.
- **Default:** open a new Terminal window.

### The connect command

- Built from the resolved connection, with every argument shell-quoted when
  typed or substituted. Pieces, in order:
  - **Base:** `ssh` + `-p <port>` (omitted when 22) + `-J <jump>`, when a
    jump host is set.
  - **1Password SSH agent**, only when the resolved credential is an SSH
    Key item:
    `-o IdentityAgent="~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"`.
    For a password login, add `-o PubkeyAuthentication=no` instead. Otherwise
    a user's many keys trigger "Too many authentication failures" before the
    password prompt. With no credential, add nothing and let the user's own
    `~/.ssh/config` decide. (My call.)
  - **Key selection:** when the credential is an SSH Key item, xpnd writes
    that key's **public** key to
    `~/Library/Application Support/xpnd/keys/<item id>.pub` and adds
    `-o IdentitiesOnly=yes -i <that file>`. Without this, a user with many
    keys in 1Password hits the server's `MaxAuthTries`. The public key isn't
    secret.
  - **Extra SSH options**, as entered.
  - **Target:** `user@host`, where user is the connection's override, else
    the credential's username field, else none.
  - **Auto-sudo:** `-t` and the remote command `sudo -i` when ticked.
- **Jump hosts (my calls):**
  - **Free text:** becomes `-J <text>`.
  - **A saved connection:** becomes a `ProxyCommand` that runs `ssh -W %h:%p`
    against it, with that connection's own agent, `IdentitiesOnly` and `-i`.
    `-J` can't carry per-hop key selection, so this is what lets a jump host
    pick its own key.
  - **Jump hosts must use key authentication in this project.** A saved jump
    host whose credential is a password is refused in the editor, with a
    note.

### Passwords at connect time

- **When:**
  - The resolved login credential is a password login (Login or Password
    item, no SSH key) and the connection is SSH.
  - Or auto-sudo is on.
  - Or the connection is VNC.
- **What happens:** after launching, xpnd fetches the relevant password from
  the provider (1Password shows Touch ID). It puts the password on the
  clipboard with the concealed and transient markers, and clears it after
  30 s, only if the clipboard still holds it (`changeCount` check). It then
  shows a brief HUD message: "Password copied for aws-external-web-services"
  or "Sudo password copied". If both are needed, the login password comes
  first; the sudo password replaces it when the user presses the HUD's
  "Next: sudo password" button, or after the first is pasted (the builder
  chooses one simple, reliable trigger).
- xpnd never types a password into another app.

### VNC

- Opens `vnc://<user>@<host>:<port>` with `NSWorkspace`, without the
  password in the URL. The password is copied as above.

### Failures

- Any failure shows a one-line HUD message and changes nothing else:
  - `op` missing
  - 1Password locked or integration off
  - item missing
  - AppleScript denied
  - terminal app not installed
- Messages never include secrets.

## Credentials

### The provider boundary

- A small interface with:
  - availability and status: installed, signed in, accounts
  - item search: by title, with category, vault and username
  - reading a field: username, password
  - for SSH Key items: the public key
- References are provider-tagged (`provider: 1password`). Only 1Password is
  implemented now. Bitwarden later adds a second implementation and a
  provider picker in Settings.

### 1Password

- **Integration:**
  - Uses the `op` CLI with the 1Password desktop app integration, so lookups
    unlock with Touch ID. No service-account tokens.
  - Finds `op` at `/opt/homebrew/bin/op`, `/usr/local/bin/op`, or a path set
    in Settings.
  - Runs it through the existing `ProcessRunner` (no shell, timeouts).
- **Settings → Password manager** shows:
  - whether `op` was found and whether the integration works (`op whoami`,
    `op account list`)
  - an account picker if there is more than one account
  - the **global credential**
  - a short note on turning on "Integrate with 1Password CLI" in the
    1Password app
- **"Choose from 1Password…":**
  - Available wherever a credential can be set (global, folder, connection,
    sudo).
  - Opens a sheet with a search field over `op item list` results. It
    covers the Login, Password, SSH Key and Server categories, and shows
    title, vault and username.
  - Picking stores the reference. "Clear" removes an override, so the slot
    inherits again.
- **Details panes:**
  - Each shows the **resolved** credential and where it came from: "From
    folder prod: prod-ssh (1Password)".
  - The default username is shown as a placeholder, which makes the cascade
    visible.
- **Cascade:**
  - Connection override, else the nearest ancestor folder with a credential,
    else the global credential, else none.
  - Resolved when connecting, so edits apply immediately.
  - The sudo credential defaults to the resolved login credential.
- **Non-secret details are stored; secrets never are (my call).** Picking
  an item records its title, category and username in `connections.yaml`. An
  SSH Key item's public key is written to `keys/<item id>.pub`. The Details
  panes and the command builder work from these with no `op` call and no
  Touch ID. A "Refresh from 1Password" action re-reads them. Passwords are
  read at the moment they're copied and discarded right after.
- **Order at connect time:** type or launch the SSH command first (no `op`
  call needed), then fetch and copy any password. A Touch ID prompt can never
  come between the front-app check and the typing.
- `op` reports errors on stderr. The existing `ProcessRunner` discards
  stderr, so the provider needs it captured for the missing, locked, and
  not-found error mapping.

## Constraints

- Everything in project 1's Constraints still applies:
  - Swift 6, macOS 14, SwiftPM and the Makefile from HoverEnhance
  - signing and notarization
  - exactly pinned dependencies
  - no keystroke, buffer, or secret logging
  - Sparkle stays unconfigured until release
- No new third-party dependencies are expected.
- The hardened runtime needs the Apple Events entitlement (AppleScript
  presets). Add it to an entitlements file and the Makefile's codesign step.
- `.superpowers/` must be git-ignored. It currently isn't, and brainstorming
  files live there.

## Tests the builder should include

- **Model and YAML:**
  - `connections.yaml` round trip, including IDs, nested folders, jump host
    by ID and by text, and default ports
  - a malformed file
  - default dev/prod on first launch only
- **Store:** the same file-safety cases as `SnippetStore`, through the shared
  core.
- **Namespace:**
  - a duplicate between a snippet keyword and a connection or folder string
    is refused, in both directions, with the owner named
  - the default folder string is derived from the name
- **Cascade:** override, nearest ancestor, global, and none; the sudo
  default.
- **Command builder:**
  - port 22 omitted
  - jump host (saved connection and text)
  - agent socket and `IdentitiesOnly`/`-i` for SSH Key items
  - extra options split with quotes
  - auto-sudo `-t sudo -i`
  - shell-quoting of hostile host, user, and option values
- **Engine:**
  - connection and folder strings trigger connection actions, not text
  - the front-app guard and "targets xpnd" skip apply
  - no backspaces on failure
- **Connection launcher:** filter ranking, folder-path matching, tree-mode
  ordering, and both hotkeys persisting independently with their defaults.
- **Quick menu logic:**
  - numbering, digit picks, subfolder navigation, more than 9 items
  - an empty folder
- **Launcher:**
  - custom template substitution with quoting
  - the preset fallback rules
  - with a fake process runner, never a real terminal
- **Provider:**
  - parsing `op` JSON output (item list, whoami, account list) from
    fixtures
  - error mapping (missing, locked, not found)
  - the clipboard copy uses concealed and transient types and clears only
    if unchanged

## Left to the builder

- How the engine represents connection actions alongside snippets.
- How the store's file-safety core is shared.
- The exact AppKit/SwiftUI structure of the main window and outline. Drag
  to reorder or move is welcome if cheap, but not required; "Move to…" in
  the right-click menu is enough.
- Exact preset commands per terminal, verified on current versions.
- The trigger for the second ("sudo") copy when both passwords are needed.
- Icons.
