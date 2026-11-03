# Changelog

All notable changes to this project will be documented in this file.

## 0.2.0 - Unreleased

### Added

- Connections to SSH and VNC servers, kept in folders and in a YAML file you can edit by hand.
- Typing a connection's activation string connects, and typing a folder's opens a numbered menu of its connections.
- A connection launcher, opened by Control-Option-Command-C, searches your connections.
- Connecting types the command into a terminal that's in front, or opens Terminal, iTerm2, Ghostty, or your own command.
- Connections can use 1Password items for the login, an SSH key, and the sudo password, set per connection, per folder, or for all of them.
- Passwords are copied concealed and cleared after 30 seconds, and are never typed.
- Connections can jump through another saved connection or a typed host, add SSH options, and offer the sudo password after login.
- Import and export connections as YAML, with a preview of what will run before anything is added.

### Changed

- xpnd is now a Dock app with a main window for connections and snippets, and it keeps running in the menu bar when you close it.
- Snippets are edited in the main window instead of Settings.
- Settings has General, Terminal, Password Manager, and Import/Export sections.

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
