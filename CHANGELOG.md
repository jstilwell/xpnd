# Changelog

All notable changes to this project will be documented in this file.

## 0.2.0 - Unreleased

### Fixed
- The import preview lists the existing connections a Replace removes even when the file adds only folders.
- The color picker's swatches show their colors in the open menu instead of white circles.
- A folder string like `;dev` is now deleted when you pick a row from its menu, not before the menu opens, so none of it is left behind in the terminal; Esc keeps what you typed.
- With more than one 1Password account, Settings → Password Manager asks which is yours instead of guessing the first, and the status check now asks 1Password for access rather than reporting "not signed in" on a working setup.

### Added
- RDP connections: Windows desktops open as tabs beside SSH, with the domain login (`DOMAIN\user` or a separate domain) and password from 1Password, an RD Gateway, dynamic resize or a fixed size letterboxed in the tab, certificate and login prompts (asked again at once when the server rejects the login), and auto-reconnect after a lost connection. Settings → Remote Desktop and each connection's RDP options set the display, clipboard and sound. FreeRDP (Apache 2.0) is bundled.
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
