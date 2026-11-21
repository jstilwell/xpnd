# Changelog

All notable changes to this project will be documented in this file.

## 0.5.0 - 11-21-2026

### Added
- Favorites: star a connection in its Details or right-click menu. With nothing typed, the connection launcher lists your favorites and your last five connections above the folders, and while you search they come first among equal matches.
- Notes on a connection: free text in its Details, which the launcher searches too.
- Settings → Import/Export → Import from SSH Config… adds the hosts in `~/.ssh/config` (HostName, User, Port, IdentityFile, ProxyJump), through the same preview as any import. Patterns like `Host *`, `Include` and `Match` are left out and the preview says so.
- A built-in tab whose ssh failed shows Reconnect, which connects again in the same tab position. Exit status 255 now reads "ssh couldn't connect" instead of a bare number.
- Undo (⌘Z) for deleting, moving and importing snippets, groups, connections and folders. It puts back only what that action changed, so edits made since stay. Only a folder or group with things in it still asks before it goes.
- Right-click a snippet to duplicate it, turn it on or off, move it to another group, or copy its keyword; right-click a group to rename it or turn it on or off. A folder's Details has New Connection and Delete buttons.
- A File menu (New Snippet ⌘N, New Snippet Group, New Connection, Import…, Export…), Edit → Find (⌘F) for the sidebar search, About, Hide and Minimize. The menu bar menu has Open Connection Launcher, and both it and Open Picker show their shortcuts.
- New installs start with a `;date` snippet, and the welcome screen shows the menu bar icon, both shortcuts, and where snippets are edited.
- The picker shows each snippet's group, and says so when nothing matches or there are no snippets yet.
- New variables: `#{input:Label=default}`, `#{choice:Label:a|b|c}` (a pop-up in the input form), `#{longInput:Label}` (several lines), `#{selection}` (the selected text, from the picker), `#{uuid}`, `#{fullName}`, `#{date:+1d}` and `#{time:+2h}`, and `:trim`, `:upper` or `:lower` on `#{clipboard}` and `#{selection}`.
- The snippet editor shows a live preview of what the snippet will type, with fields to try its inputs. Scripts, keys, apps and Shortcuts never run there, and the clipboard is never read.
- Insert Variable opens a form for each variable, and right-clicking a variable offers Edit Variable….
- Variables are coloured in the editor, and one that won't expand gets a red underline with a tooltip saying why.
- New Snippet from Clipboard in the menu bar menu. A copied password is refused.
- ssh connections get a 15-second connect timeout and a 30-second keepalive, after a connection's own SSH options. Turn it off in Settings → Terminal if you set them in `~/.ssh/config`.

### Changed
- In `#{input:…}`, an `=` now starts the field's default: `#{input:Name=Ann}` asks for "Name", filled with "Ann". A label that had an `=` in it is split there.
- Importing with conflicts: Replace is marked as the destructive choice, and Skip is the default.
- A disabled snippet, or one in a disabled group, shows dimmed, with a tooltip and "Off" for VoiceOver. Icon-only buttons have tooltips, and the drop drive and NLA options say what they do.
- A strict snippet (the default) now expands when you finish the word, on the space or punctuation after its keyword, which is typed back after the text: `;sig ` becomes `Best `. It no longer fires inside a longer word (`the` in "then"), and a keyword can follow `(` or a quote. Return and Tab don't expand it. Loose snippets still expand the moment you type them.
- The warning that one keyword starts another now appears only when the shorter one fires at once: a loose snippet, or a connection or folder string.

### Fixed
- A snippet pasted into a slow app (Electron or Office under load) no longer pastes your old clipboard instead: xpnd now waits until the app has read the snippet, up to a second, before putting your clipboard back. Your clipboard is saved once per snippet rather than at each piece of text, and is put back before a keyboard shortcut, delay, Open App or Run Shortcut, so `#{shortcut:Cmd+V}` pastes your clipboard and a Shortcut never reads the snippet's text.
- A snippet that includes itself, directly or through others, now says so instead of pasting `#{combo:…}` as text, and snippets nested too deeply (over 16 levels, or so many copies that they would freeze xpnd) stop with a message before anything is typed.
- A Run Shortcut snippet lists your Shortcuts once instead of twice, and when the list can't be read it says so instead of claiming the Shortcut doesn't exist. A script without execute permission says to run `chmod +x` instead of "No script was found".
- A keyword or activation string now saves when you pause typing or press Return, not on every key, so a half-typed `;s` can't fire while you type `;sig`.
- While 1Password or the Keychain waits for Touch ID to open a Windows desktop, snippets and other connections keep working, and a HUD says what it's waiting for. If the item or its password is missing, the desktop opens and Windows asks for the password instead of stopping.
- Connecting to a second host no longer cancels a password still waiting to be sent into the first host's tab.
- Clearing a Windows desktop's drop folder no longer runs on the main thread, so a large folder can't stall the app, and a copy still in progress can't recreate it afterwards.
- Keys typed while a snippet expands are no longer lost or put in front of it: typing `;sig` and carrying on quickly kept the space and let the backspaces eat the keyword's last letters instead. They're typed again after the snippet. If an arrow, Return or other key may have moved the cursor meanwhile, the snippet is cancelled and says so, rather than deleting the wrong text.

## 0.4.0 - 11-15-2026

### Changed
- **Send automatically** types a built-in tab's password by itself only for 15 seconds; after that **Send Password** sends it, for the rest of the minute. A later prompt may be another login's, such as `ssh` to a second server from a root shell that needed no sudo password.
- A keyword or activation string that starts another one (`;d` and `;db`) gets a warning in its editor: typing the longer one fires the shorter first.
- The Details fields (names, host, username, domain, SSH options, jump host, gateway host, alternate shell, a group's name and description) save when typing pauses, on Return, or when you leave them, not on every key, like a snippet's text since 0.3.1.
- A Windows desktop tab shows **Connecting…** while it connects and while it reconnects by itself, instead of a black tab.

### Fixed
- ⌥⌫ (delete a word) no longer leaves xpnd's idea of what you typed out of step, which could make a later keyword delete text you had typed before it.
- "Password copied" shows over the tab that just connected, not another tab of the same connection that may sit at a shell prompt, where pasting would run the password as a command.
- A snippet or connection file that is a symlink to a folder that's offline (Dropbox, iCloud) now shows an error instead of an empty library, and editing no longer replaces the link with a new file.
- A snippet script that prints without end (`yes`, a runaway loop) is stopped once it has printed 8 MB, instead of filling memory until it times out, or forever with no timeout.
- Clearing a Windows desktop's **Gateway host** to retype it no longer deletes the gateway's port and login.
- Importing connections keeps the logins the file gave them. The file's global and folder credentials were dropped, so imported connections used this Mac's credential for a folder of the same name, or none; now they fill levels that have none here, and a connection that would inherit a different one keeps the file's as its own.
- Importing no longer brings in a snippet keyword a connection or folder already answers to, or the other way round, which left both doing nothing. The preview lists what's left out: such snippets aren't imported, and such connections come without their string.
- The snippet import preview lists snippets whose text has a new line, which presses Return when typed as keystrokes, and the message after an import says when snippets went into a group that's turned off.
- After a Windows desktop reconnects, pasting in Windows no longer gives what you copied on the Mac before something you copied in Windows since, and files dropped earlier aren't offered to Windows again.
- The end of a gentle downward scroll on a trackpad no longer jumps a Windows desktop two notches.
- A snippet with `#{runShortcut:}` or `#{openApp:}` naming a Shortcut or app that isn't there fails before anything changes, as the README says, instead of deleting the keyword and typing half the snippet.
- Picking a snippet while another one is still running says so, instead of closing the picker and doing nothing; turning expansion off while a snippet waits says that, not that you left the app.
- Typing a snippet as keystrokes (Screen Sharing, VNC, Windows desktops) uses the main keys for `*` and `+`, not the keypad's, which terminals in keypad mode read as escape codes; and on layouts with dead keys (US International's `'` and `"`) those characters reach the remote machine instead of an "a".
- A mistake in a hand-edited snippets or connections file is described in a sentence ("groups › item 1 › snippets › item 2 has no “text”.") instead of Swift's error dump, and a credential written without `provider:` is read as 1Password instead of making the whole file unreadable.
- ⌘C, ⌘V, ⌘X, ⌘Z and ⌘A reach a Windows desktop as Ctrl shortcuts with a Russian, Greek or other non-Latin input source too, instead of going to xpnd's Edit menu.
- More of the reasons a Windows login is refused are said in words (an account that isn't in Remote Desktop Users, an expired account, missing permission, a server that's still starting...), instead of names like `ERRCONNECT_LOGON_TYPE_NOT_GRANTED`.
- A built-in tab's LANG is always one a server accepts (`zh_CN.UTF-8`, not `zh-Hans_CN.UTF-8`), which ssh passes on and which made servers print "cannot change locale".
- Sending a password into a built-in tab works at a sudo or login prompt in German, French, Spanish, Japanese and other languages, not only English.
- Changing a connection's type with its old default port in the Port field (22, then VNC) clears the field to show the new default, instead of showing 22 and connecting on 5900.
- A nameless item is "Untitled" everywhere, including the question before deleting it; a group's **+** and switch name the group for VoiceOver; and an empty Connections or Snippets list says what to add first.
- A gateway with no login of its own says it uses the connection's login, instead of looking as if one were set.

## 0.3.1 - 11-10-2026

### Changed
- **Importing snippets always shows what will be added** before anything is imported, and lists snippets that press keys along with those that run scripts, open apps, run Shortcuts or send shortcuts.
- A Windows desktop with **Network Level Authentication** on now connects with it or not at all, and the old "RDP security" mode is never used. For a server without Network Level Authentication, turn the option off for that connection.
- **Delete** (⌫) deletes the item selected in the sidebar, snippets and groups have a right-click **Delete…**, and a connection's Details has **Delete Connection…**.
- The snippet picker, the connection launcher, the sidebar and the 1Password chooser do less work per key press, which shows with large libraries. The 1Password chooser lists an account once and filters as you type, and has **Try Again** after an error.
- A snippet's text is saved when typing pauses, not on every key, which kept large libraries and synced folders busy.

- A connection's extra SSH options now come before the ones xpnd adds for its credential, so yours win (ssh keeps the first value it is given): `-o PubkeyAuthentication=yes` reaches a server that wants a key and a password.
- Messages in the corner of the screen stay up longer the longer they are, and VoiceOver reads them.

### Fixed
- A snippet's input form closes when you switch to another app, which cancels the expansion: it used to stay open, take an answer and throw it away, and stop every other keyword until it was closed.
- **Send Password** goes to the tab that just opened, not to another tab of the same connection, and ends when its tab closes.
- Deleting a snippet or a connection asks first, like deleting a group or a folder that holds something: a delete can't be undone.
- A new connection now shows in the sidebar: its folder opens, as does every folder above anything you select.
- Recording a shortcut in Settings no longer swallows keys typed in other xpnd windows, such as a terminal tab.
- A Windows password could be sent to a server that skipped Network Level Authentication, without a certificate question.
- Expanding a snippet on the Mac no longer offers it to connected Windows desktops, or replaces what you copied in Windows.
- A refused Windows login says why in the password sheet, and cancelling it ends the tab with that reason instead of "cancelled". "Access denied" no longer looks like a wrong password.
- A Windows desktop on a non-Retina screen is no longer drawn at double size.
- Taking a screenshot (⌘⇧4) or using another ⌘ shortcut of macOS's in a Windows desktop no longer opens the Start menu; nor does ⌘ with a scroll.
- Importing says how many snippets or connections it added and skipped, and says so when a file holds none, instead of "Imported." every time. File errors read as sentences.

## 0.3.0 - 11-07-2026

### Added
- **Use the macOS Keychain instead of 1Password** in Settings → Password Manager, with **New Password** in the credential picker.
- A warning when a terminal's Secure Keyboard Entry hides keywords from xpnd.
- Built-in terminal tabs show when a login or sudo password is on the clipboard, with a countdown and **Clear**.
- **Passwords** setting for built-in tabs: **Copy to clipboard**, **Send on click** (⌘⇧P), or **Send automatically** at the password prompt.

### Fixed
- Passwords and expanded snippets no longer reach your other devices through Universal Clipboard.
- Switching apps or turning expansion off stops a snippet's running script, so a stuck script no longer blocks every keyword.
- Saving no longer replaces a symlinked `snippets.yaml` or `connections.yaml` with a plain file.
- A VNC username containing `:` is no longer split into a username and password.

## 0.2.1 - 11-06-2026

### Fixed
- xpnd no longer crashes while connected to a Windows desktop when that desktop shows its own mouse pointer.

### Changed
- The copyright holder is Jesse Stilwell, and the app no longer says "All rights reserved", which didn't fit the MIT license.

## 0.2.0 - 11-06-2026

### Fixed
- The mouse pointer in a Windows desktop tab is the right size with Retina on, instead of twice as big.
- A Windows desktop tab no longer covers the tab bar, so you can switch tabs while it is showing.
- The import preview lists the existing connections a Replace removes even when the file adds only folders.
- The color picker's swatches show their colors in the open menu instead of white circles.
- A folder string like `;dev` is now deleted when you pick a row from its menu, not before the menu opens, so none of it is left behind in the terminal; Esc keeps what you typed.
- With more than one 1Password account, Settings → Password Manager asks which is yours instead of guessing the first, and the status check now asks 1Password for access rather than reporting "not signed in" on a working setup.
- Settings → Password Manager has a "Use the login for sudo" switch; turn it off to stop sudo falling back to the login password, so you can have no global sudo password without clearing the login.

### Added
- xpnd checks for updates and installs them, with signed releases from updates.xpnd.dev.
- xpnd has its own app icon and menu bar symbol: a prompt with lines growing out of it.
- A folder can have an icon (terminal, PC, desktop, server rack, network, cloud, shield, home or building) in its Details, to tell Linux and Windows folders apart at a glance. It shows in the sidebar, the folder menu and the launcher; subfolders don't inherit it.
- A small green dot at the right of a sidebar row shows a connection that is connected in a tab.
- A connection open in a tab can be disconnected from its sidebar menu or its Details (Disconnect, after the usual confirmation), even while it is still connecting, and Show Session jumps to its tab.
- RDP connections: Windows desktops open as tabs beside SSH, with the domain login (`DOMAIN\user` or a separate domain) and password from 1Password, an RD Gateway, dynamic resize or a fixed size letterboxed in the tab, certificate and login prompts (asked again at once when the server rejects the login), and auto-reconnect after a lost connection. Settings → Remote Desktop and each connection's RDP options set the display, clipboard and sound. FreeRDP (Apache 2.0) is bundled.
- A Windows desktop tab shares a per-connection drop folder as drive `xpnd`; Settings → Remote Desktop and each connection's RDP options turn it on or off, and Settings → Remote Desktop clears the folders never, on disconnect or after 7 days, or right away.
- A toolbar at the top of a Windows desktop tab (point at the top edge, or ⌘⇧N) has Ctrl+Alt+Del, Win+R, full screen, display size (with "Set as this connection's default"), audio, clipboard sync, the drop folder, Reconnect, Disconnect and connection details.
- Files dropped from Finder onto a Windows desktop are pasted into the window under the pointer; dropped on the toolbar they are copied into the `xpnd` drive.
- Files and folders copied in Finder can be pasted into a Windows desktop tab.
- Snippets are typed into a Windows desktop tab as keystrokes.
- Snippets typed in Screen Sharing, VNC and RDP clients, and VMs are typed as keystrokes on the remote machine instead of pasted; Settings → General can type them everywhere.
- A “+” on each snippet group row and “New Snippet” in its right-click menu add a snippet to it; double-clicking a folder or group opens or closes it.
- Hold ⌘ while picking a connection in a folder menu, the launcher, or when double-clicking it in the window, to connect with sudo just that once, using its sudo credential, its folder's or the global one.
- Folders and connections can have a color from a small palette; a connection without one takes the nearest folder's, and the name shows in that color in the sidebar, the folder menu and the launcher.
- A built-in terminal: double-clicking a connection (or Connect) opens it as a tab on the right of the main window, and a tab can be duplicated or closed. The editor opens over the tabs as a card, and snippets expand inside tabs.
- "xpnd (built-in)" is a choice in Settings → Terminal for when no terminal is in front; typing a connection's string while a tab is focused opens a new tab.
- Settings → Terminal → Built-in terminal sets the font, size, colors, cursor, blink and scrollback.
- Closing the window or quitting asks before it terminates open terminal sessions.

- Connections to SSH and VNC servers, kept in folders and in a YAML file you can edit by hand.
- Typing a connection's activation string connects, and typing a folder's opens a numbered menu of its connections.
- A connection launcher, opened by Control-Option-Command-C, searches your connections.
- Connecting types the command into a terminal that's in front, or opens Terminal, iTerm2, Ghostty, or your own command.
- Connections can use 1Password items for the login, an SSH key, and the sudo password, set per connection, per folder, or for all of them.
- Passwords are copied concealed and cleared after 30 seconds unless you've copied something else since, and are never typed.
- Connections can jump through a typed host, or through another saved connection that uses a 1Password SSH key, add SSH options, and offer the sudo password after login.
- Import and export connections as YAML, with a preview of what will run, and of existing connections a Replace removes or re-points, before anything changes.
- The main window's sidebar search filters snippets and connections.
- A broken `connections.yaml` is flagged in the HUD and the menu bar menu, and pauses only connection strings.

### Changed
- Drag connections, folders, snippets and snippet groups in the sidebar to reorder them or move them into another folder or group; dropping under a folder puts the item in it.
- The sidebar adds folders, connections and snippet groups from a “+” beside each heading, and shows the version and a Settings button at the bottom.
- xpnd is now a Dock app with a main window for connections and snippets, and it keeps running in the menu bar when you close it.
- Snippets are edited in the main window instead of Settings.
- Settings has General, Terminal, Password Manager, and Import/Export sections.
- A broken `snippets.yaml` pauses only snippets, and the HUD says connection strings still work.

## 0.1.0 - Unreleased

### Added

- Typing a keyword in any app replaces it with its snippet's text, strictly (the whole word) or loosely (the end of what you've typed).
- Snippets can use variables for the clipboard, the date and time (with shifts and custom formats), environment variables, and other snippets.
- A snippet can ask for values when it fires, in one small form near the window you're typing in.
- If you switch to another app while a snippet's form is open or its script runs, the expansion is cancelled instead of being typed into the wrong app.
- A snippet can press keys, send a shortcut, wait, put the caret where you want it, open an app, run a macOS Shortcut, or run a script.
- Your clipboard is put back, with everything on it, after each expansion.
- A picker, opened by a shortcut you can change (Control-Option-Command-Space to start), searches snippets and inserts the one you choose.
- Settings has groups of snippets you can turn on or off, an editor with an Insert Variable menu, and general options for launching at login and turning expansion off.
- Snippets live in a YAML file you can edit by hand, and xpnd reloads it when it changes.
- Import and export snippets as YAML, choosing what happens to keywords that already exist, and confirming any imported snippet that would run a script, open an app, run a Shortcut, or send a keyboard shortcut.
- The menu bar icon turns expansion on or off, opens the picker and Settings, and offers update checks once releases are set up.
- A welcome window walks you through allowing Input Monitoring and Accessibility.
- Signed updates through Sparkle, which you can turn off in Settings.
