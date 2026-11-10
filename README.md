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

- **Keywords**: type one and it's replaced. Keywords are case-sensitive. A strict snippet (the default) expands when the whole word matches; a loose one when what you typed ends with it. Space, Return, Tab, arrows, a click, or switching apps start the word over. If you switch apps while a snippet's form is open or its script runs, the expansion is cancelled (and the script stopped) rather than typed into the wrong app. Keywords can't be seen in password fields or in a terminal with Secure Keyboard Entry on.
- **Picker**: press Control-Option-Command-Space (changeable in Settings) to search snippets by keyword, name, or text, and press Return to insert one.
- **Groups**: snippets sit in groups you can turn on or off together.
- **Editing**: snippets are edited in the xpnd window. Its sidebar search filters snippets by keyword, name, or text, and connections by name, host, activation string, or folder. To delete a snippet, group, connection or folder, select it and press Delete, right-click it, or use the button in its Details; xpnd asks first, since a delete can't be undone. A snippet's text is saved when you pause typing.
- **Import and export**: share snippets as YAML. Importing first lists every snippet the file adds, and calls out any that runs a script, opens an app, runs a Shortcut, sends a keyboard shortcut or presses a key; nothing is added until you confirm.

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

Keep your SSH, VNC and RDP connections in folders and open them by typing, from the launcher, or from the xpnd window (it has a Dock icon; closing it leaves xpnd running in the menu bar).

- **Activation strings**: give a connection a string such as `;aws` and typing it connects. A folder opens a numbered menu instead: press 1 to 9 to connect, the arrows and Return to pick, Esc to close and keep what you typed. A folder named `prod` gets `;prod` unless you set another or none. It gets none if `;prod` is taken, or would cut off a longer snippet keyword or a string you set, such as `;prod2`. Snippets and connections share one set of strings, and xpnd flags one used twice.
- **Colors**: give a folder or connection a color (red, orange, yellow, green, blue, purple or gray) in its Details. A connection without one takes the nearest folder's, and its name shows in that color in the sidebar, the folder menu and the launcher. In YAML it is `color: blue`.
- **Icons**: give a folder an icon (terminal, PC, desktop, server rack, network, cloud, shield, home or building) in its Details. It replaces the folder symbol in the sidebar, the folder menu and the launcher, and subfolders don't inherit it. In YAML it is `icon: terminal`.
- **⌘ for sudo**: hold ⌘ while picking a connection in a folder menu (⌘1, ⌘Return or a ⌘-click), in the launcher (⌘Return or ⌘-double-click), or when double-clicking it in the window, and that one connect runs with auto-sudo on, using the connection's sudo credential, its folder's or the global one.
- **Launcher**: press Control-Option-Command-C (changeable in Settings) to search connections and press Return to connect.
- **Built-in terminal**: double-clicking a connection in the window (or Connect) opens it as a tab in xpnd's own terminal, on the right; duplicate or close a tab from its menu. Typed strings still go to your external terminal as below (a string typed inside a tab opens a new tab), and the choice of default is in Settings → Terminal (pick "xpnd (built-in)" to open tabs instead). Closing the window or quitting asks before it ends open sessions.
- **Remote desktop (RDP)**: double-clicking an RDP connection opens the Windows desktop as a tab beside your terminals, using the FreeRDP library bundled in xpnd. The login (user, domain, password) comes from 1Password; the password goes straight to the session and is never copied or typed. It resizes with the tab, asks about unknown or changed certificates and bad passwords, and reconnects after a drop. With Network Level Authentication on (the default) it connects that way or not at all; turn it off for a server that doesn't support it, and the connection uses TLS with the certificate question. Defaults are in Settings → Remote Desktop and can be overridden in a connection's RDP options. Snippets are typed into the tab as keystrokes.
- **Desktop toolbar (the notch)**: point at the top edge of a Windows desktop, or press ⌘⇧N, for a toolbar with Ctrl+Alt+Del, Win+R, full screen, display size, audio, clipboard sync on or off for the session, the file drop drive, Reconnect, Disconnect and connection details; the pin keeps it open. It acts on the session without changing the saved options, except "Set as this connection's default" in the display panel.
- **Dropping files on a Windows desktop**: drop Finder files on the desktop and xpnd pastes them into the window under the pointer, as if you had copied them in Finder (needs clipboard sync on). It clicks and pastes only once Windows has taken the files; otherwise it says it couldn't, and nothing is clicked or typed. Drop them on the toolbar instead to copy them into the `xpnd` drive, a per-connection folder Windows sees as `This PC → xpnd` (`\\tsclient\xpnd`) and nothing else of your Mac. Files Windows saves there appear in it too. Folders aren't copied into the drive. The drive and when its folder is cleared are set in Settings → Remote Desktop and each connection's RDP options.
- **Connected and Disconnect**: a green dot on a row means it is connected in a tab; a Windows desktop still connecting or reconnecting has none. While a tab is open, connected or not yet, the row's right-click menu (and Details) has Disconnect, after the usual confirmation, and Show Session to jump to the tab.
- **Terminal**: if a terminal (Terminal, iTerm2, Ghostty, Warp, or others you add in Settings → Terminal) is in front, the command is typed into it. Otherwise xpnd opens a new Terminal window, or whatever you pick under "Open in" (iTerm2, Ghostty, or your own command with `{command}`, which is how to reach Warp). A VNC connection opens its `vnc://` address in your default viewer, Screen Sharing unless you changed it.
- **Credentials**: a connection uses its own 1Password item, else its folder's (nearest first), else the global one from Settings → Password Manager. A sudo item falls back the same way, then to the login password (Settings → Password Manager can turn that last step off). An SSH key is used through the 1Password SSH agent. A password is copied to the clipboard, marked concealed, kept to this Mac (no Universal Clipboard), and cleared after 30 seconds unless you've copied something else since. With "Auto-sudo" on, it offers the sudo password after the login one. In the built-in terminal, Settings → Terminal → **Passwords** can instead send them into the tab: on a click (**Send Password**, ⌘⇧P) or automatically at the next password prompt within a minute. Either way xpnd only types at a line that looks like a password prompt, once per prompt; external terminals always use the clipboard.
- **1Password setup**: install the [1Password CLI](https://developer.1password.com/docs/cli/get-started/) (`op`), turn on Integrate with 1Password CLI in 1Password → Settings → Developer, then pick items in Settings → Password Manager or a connection's details. SSH keys also need the 1Password SSH agent turned on.
- **macOS Keychain instead**: no 1Password? Turn on "Use the macOS Keychain instead of 1Password" in Settings → Password Manager, then use Choose… → New Password to save a password in your login keychain. Passwords only; SSH keys stay in `~/.ssh`. Credentials you picked from 1Password keep working.
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
        port: 2222                # omit for 22 (SSH), 5900 (VNC) or 3389 (RDP)
        username: deploy
        type: ssh                 # ssh | vnc | rdp
        advanced:
          jumpHost:
            connection: 6F1B0C52-3A41-4E5B-9D0A-1C2D3E4F5A01   # or text: user@host
          sshOptions: "-o ServerAliveInterval=30"
          autoSudo: true
      - name: win-01
        host: win-01.corp.example.com
        type: rdp
        username: jdoe            # or CORP\jdoe, or jdoe@corp.example.com
        domain: CORP              # optional
        rdp:                      # optional; unset keys use Settings → Remote Desktop
          display: 1920x1080      # or fit
          gateway:
            host: gw.corp.example.com
```

A jump host chosen from your saved connections must be an SSH connection whose login credential is a 1Password SSH key, or connecting shows an error; a typed jump host (`text:`) has no such requirement. A chain of saved jump hosts can be at most 5 hops long.

Credentials are 1Password or Keychain references (`credential` and `sudoCredential` on a connection, folder, or the file) that Settings fills in for you. Keychain references point at your own Mac's keychain, so they don't carry over to another Mac.

## Privacy

- xpnd keeps up to the last 128 characters you typed, in memory only, to match keywords. They're never stored, logged, or sent anywhere.
- It puts your clipboard back after each expansion.
- xpnd stores no passwords or keys, only references to 1Password items and the public key of an SSH key item (under `~/Library/Application Support/xpnd/keys`).
- It runs `op` when you connect, pick or refresh a credential, open Settings → Password Manager, or save a new `op` path there, never in the background. A password is copied concealed and cleared after 30 seconds (unless you've copied something else since), or when you quit.
- Its only network use is the optional update check against GitHub, which you can turn off in Settings.

## Building

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Building needs Xcode and [CMake](https://cmake.org) (`brew install cmake` is fine). The first build runs `make freerdp`, which compiles FreeRDP and OpenSSL into `vendor/FreeRDP.xcframework` (about 5 minutes; later builds reuse it), and `make build` and `make test` run it when it is missing. xpnd is MIT licensed; the app bundles FreeRDP and OpenSSL (Apache 2.0), and their licences ship in the app's Resources.
