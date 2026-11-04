<h1 align="center">xpnd</h1>

<p align="center">
  <strong>Text expansion and a connection manager for the Mac.</strong><br>
  Type a keyword in any app and it becomes your snippet: text with the date, the clipboard, or
  values you're asked for, and keywords that open an app or run a Shortcut. Type another and it
  opens an SSH or VNC connection.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Swift-native-F05138?logo=swift&logoColor=white" alt="Native Swift">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/jstilwell/xpnd?color=blue" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/jstilwell/xpnd/releases/latest"><strong>Download</strong></a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

## Install

1. Download the DMG from the [latest release](https://github.com/jstilwell/xpnd/releases/latest) and drag xpnd to Applications. It needs macOS 14 or later.
2. Open it. The welcome window asks for **Input Monitoring** (to notice a keyword as you type it) and **Accessibility** (to type the snippet in its place).
3. The xpnd window opens: add snippets and connections in its sidebar. Closing it leaves xpnd running in the menu bar, where "Open xpnd…" brings it back.

## Using it

- **Keywords**: type one and it's replaced. Keywords are case-sensitive. A strict snippet (the default) expands when the whole word matches; a loose one when what you typed ends with it. Space, Return, Tab, arrows, a click, or switching apps start the word over. If you switch apps while a snippet's form is open or its script runs, the expansion is cancelled rather than typed into the wrong app.
- **Picker**: press Control-Option-Command-Space (changeable in Settings) to search snippets by keyword, name, or text, and press Return to insert one.
- **Groups**: snippets sit in groups you can turn on or off together.
- **Editing**: snippets are edited in the xpnd window. Its sidebar search filters snippets by keyword, name, or text, and connections by name, host, activation string, or folder.
- **Import and export**: share snippets as YAML. Importing asks before it adds a snippet that runs a script, opens an app, runs a Shortcut, or sends a keyboard shortcut.

## Variables

Written `#{name}` or `#{name:value}`. Names are case-sensitive, and unknown ones are left as typed. Use `\}` and `\\` for a literal `}` and `\`.

| Variable | Inserts or does |
|---|---|
| `#{clipboard}` | The clipboard's text |
| `#{date}` `#{time}` `#{dateTime}` | The current date and time |
| `#{dateTime:<format>}` | A custom format, such as `yyyy-MM-dd` |
| `#{dateTime:<shift>:<format>}` | Shifted by `y M w d h m s`, signed, such as `+1d-2h` |
| `#{combo:<keyword>}` | Another snippet's text |
| `#{upper:<keyword>}` `#{lower:<keyword>}` | Another snippet's text, in upper or lower case |
| `#{cursor}` | Where the caret ends up |
| `#{input:<label>}` | Asks for a value |
| `#{envVar:<name>}` | An environment variable |
| `#{shell:<path>[:<timeoutMs>]}` | The output of the script at that path (10 seconds by default; `0` for no limit) |
| `#{key:<name>[:<count>]}` | Presses a key: tab, enter, space, delete, arrows, home, end, f1 to f20, and more |
| `#{shortcut:<keys>}` | Sends a shortcut, such as `Cmd+Shift+J` |
| `#{delay:<ms>}` | Waits |
| `#{openApp:<path>}` | Opens the app at that path |
| `#{runShortcut:<name>}` | Runs a macOS Shortcut by name |

If a value can't be worked out (a script fails, a form is cancelled), nothing changes and your keyword stays where it is.

## Snippet file

Snippets are kept in `~/Library/Application Support/xpnd/snippets.yaml`, the same format export writes. Edit it by hand and xpnd reloads it. Saving from the app rewrites the file and drops comments. If the file can't be read, xpnd leaves it alone and pauses snippets until it's fixed; connection strings keep working.

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

## Connections

Keep your SSH and VNC connections in folders and open them by typing, from the launcher, or from the xpnd window (it has a Dock icon; closing it leaves xpnd running in the menu bar).

- **Activation strings**: give a connection a string such as `;aws` and typing it connects. A folder opens a numbered menu instead: press 1 to 9 to connect, the arrows and Return to pick, Esc to close and keep what you typed. A folder named `prod` gets `;prod` unless you set another or none. It gets none if `;prod` is taken, or would cut off a longer snippet keyword or a string you set, such as `;prod2`. Snippets and connections share one set of strings, and xpnd flags one used twice.
- **Colors**: give a folder or connection a color (red, orange, yellow, green, blue, purple or gray) in its Details. A connection without one takes the nearest folder's, and its name shows in that color in the sidebar, the folder menu and the launcher. In YAML it is `color: blue`.
- **⌘ for sudo**: hold ⌘ while picking a connection in a folder menu (⌘1, ⌘Return or a ⌘-click), in the launcher (⌘Return or ⌘-double-click), or when double-clicking it in the window, and that one connect runs with auto-sudo on, using the connection's sudo credential, its folder's or the global one.
- **Launcher**: press Control-Option-Command-C (changeable in Settings) to search connections and press Return to connect.
- **Terminal**: if a terminal (Terminal, iTerm2, Ghostty, Warp, or others you add in Settings → Terminal) is in front, the command is typed into it. Otherwise xpnd opens a new Terminal window, or whatever you pick under "Open in" (iTerm2, Ghostty, or your own command with `{command}`, which is how to reach Warp). A VNC connection opens its `vnc://` address in your default viewer, Screen Sharing unless you changed it.
- **Credentials**: a connection uses its own 1Password item, else its folder's (nearest first), else the global one from Settings → Password Manager. A sudo item falls back the same way, then to the login password. An SSH key is used through the 1Password SSH agent. A password is copied to the clipboard, marked concealed, and cleared after 30 seconds unless you've copied something else since. xpnd never types it. With "Auto-sudo" on, it offers the sudo password after the login one.
- **1Password setup**: install the [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op`), turn on Integrate with 1Password CLI in 1Password → Settings → Developer, then pick items in Settings → Password Manager or a connection's details. SSH keys also need the 1Password SSH agent turned on.
- **Import and export**: Settings → Import/Export shares connections as YAML (1Password references only). Importing shows every connection, its jump host, and its SSH options before anything is added, because they run when you connect. With Replace, it also lists the existing connections it removes and those whose jump host moves to an imported one.

Connections are kept in `~/Library/Application Support/xpnd/connections.yaml`, edited like the snippet file. If it can't be read, xpnd leaves it alone and pauses connection strings until it's fixed; snippets keep working.

```yaml
version: 1
folders:
  - name: prod                    # opens the menu with ;prod
    color: blue                   # everything in prod without its own color
    connections:
      - id: 6F1B0C52-3A41-4E5B-9D0A-1C2D3E4F5A01
        name: bastion
        host: bastion.example.com
      - name: web-01
        activation: ";web1"       # optional
        host: web-01.internal
        port: 2222                # omit for 22 (SSH) or 5900 (VNC)
        username: deploy
        type: ssh                 # ssh | vnc
        advanced:
          jumpHost:
            connection: 6F1B0C52-3A41-4E5B-9D0A-1C2D3E4F5A01   # or text: user@host
          sshOptions: "-o ServerAliveInterval=30"
          autoSudo: true
```

A jump host chosen from your saved connections must be an SSH connection whose login credential is a 1Password SSH key, or connecting shows an error; a typed jump host (`text:`) has no such requirement. A chain of saved jump hosts can be at most 5 hops long.

Credentials are 1Password references (`credential` and `sudoCredential` on a connection, folder, or the file) that Settings fills in for you.

## Privacy

- xpnd keeps up to the last 128 characters you typed, in memory only, to match keywords. They're never stored, logged, or sent anywhere.
- It puts your clipboard back after each expansion.
- xpnd stores no passwords or keys, only references to 1Password items and the public key of an SSH key item (under `~/Library/Application Support/xpnd/keys`).
- It runs `op` when you connect, pick or refresh a credential, open Settings → Password Manager, or save a new `op` path there, never in the background. A password is copied concealed and cleared after 30 seconds (unless you've copied something else since), or when you quit.
- Its only network use is the optional update check against GitHub, which you can turn off in Settings.

## Building

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). xpnd is MIT licensed.
