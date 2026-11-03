<h1 align="center">xpnd</h1>

<p align="center">
  <strong>Text expansion for the Mac menu bar.</strong><br>
  Type a keyword in any app and it becomes your snippet: text with the date, the clipboard, or
  values you're asked for, and keywords that open an app or run a Shortcut.
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
3. Look for the icon in the menu bar. Open Settings to add snippets.

## Using it

- **Keywords**: type one and it's replaced. Keywords are case-sensitive. A strict snippet (the default) expands when the whole word matches; a loose one when what you typed ends with it. Space, Return, Tab, arrows, a click, or switching apps start the word over.
- **Picker**: press Control-Option-Command-Space (changeable in Settings) to search snippets by keyword, name, or text, and press Return to insert one.
- **Groups**: snippets sit in groups you can turn on or off together.
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

Snippets are kept in `~/Library/Application Support/xpnd/snippets.yaml`, the same format export writes. Edit it by hand and xpnd reloads it. Saving from the app rewrites the file and drops comments. If the file can't be read, xpnd leaves it alone and pauses expansion until it's fixed.

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

## Privacy

- xpnd keeps only the last few characters you typed, in memory, to match keywords. Keystrokes are never stored, logged, or sent anywhere.
- It puts your clipboard back after each expansion.
- Its only network use is the optional update check against GitHub, which you can turn off in Settings.

## Building

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). xpnd is MIT licensed.
