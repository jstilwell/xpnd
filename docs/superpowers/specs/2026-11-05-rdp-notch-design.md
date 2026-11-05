# RDP notch and file drop — design

2026-11-05. A fly-out toolbar on every RDP tab, and a drop-folder drive into the session.

## Intent

In a Windows desktop tab the things people reach for mid-task — Ctrl+Alt+Del, Win+R, full screen,
display and audio switches, reconnecting, and getting a file across — currently mean leaving the
tab or editing the connection. Screen-sharing apps solve this with a small handle at the top of the
session that flies out into icon buttons with tooltips. The user also wants to drop a file on that
handle and have it land on the Windows side.

## Goals

- **Notch:** every RDP tab shows a small handle at the top-centre of the desktop. Hovering it flies
  out a row of icon buttons, each with a tooltip saying what it does; a pin keeps the row open;
  ⌘⇧N toggles it from the keyboard. It collapses when the pointer leaves (unless pinned). It must
  never steal keyboard focus from the desktop except while one of its popovers is open.
- **Buttons, first version, in this order:**
  1. Ctrl+Alt+Del — sends the secure-attention sequence, as real Ctrl+Alt+Delete. (Changed from
     `Ctrl+Alt+End`: that alias is mstsc's client-side mapping, and FreeRDP forwards keys as they are.)
  2. Win+R — opens the Run box.
  3. Full screen — the tab's window goes full screen (and back); the notch stays reachable.
  4. Display — popover: Resize to fit / 1280×720 / 1920×1080 / 2560×1440 (the presets from
     `RDPOptionLabels`); applies live to this session.
  5. Audio — cycles Play here / Leave on remote / Off; the icon shows the state.
  6. Clipboard sync — on/off for this session; off also stops the pasteboard poll.
  7. Files — the drive drop zone (see below): drop files on it to put them in the `xpnd` drive,
     see how many are there, "Open in Explorer" (sends Win+R `\\tsclient\xpnd` Enter), "Show drop
     folder in Finder", "Clear drop folder".
  8. Reconnect — the same as the ended bar's Reconnect, available while connected too.
  9. Disconnect — ends the session (tab closes if it was clean).
  10. Info — popover: desktop size, codec in use, round-trip latency (FreeRDP's auto-detect or a
      ping over the channel if available; "—" otherwise), connected-for, server certificate subject
      and SHA-256, and the gateway if any.
- **Live, not saved:** display, audio and clipboard changes from the notch apply to this session
  only; the connection's stored options and Settings are untouched. The notch's Display popover has
  a "Set as this connection's default" item that writes the current choice through
  `ConnectionEditing` (my call; the rest stay session-only).
- **File drop drive:** a per-connection option "File drop drive" (default on; global default in
  Settings → Remote Desktop) redirects exactly one folder,
  `~/Library/Application Support/xpnd/drop/<connection id>/`, into the session as drive **xpnd**
  (visible as `This PC → xpnd on <Mac name>` and `\\tsclient\xpnd`). Files dropped on the notch's
  Files button are copied into that folder (not moved) and are immediately visible in Windows —
  for files you want to reach later from any Windows app. The folder is created on first use with
  `0700` permissions.
- **Drop on the desktop = paste it there** (decided by the user): files dropped from Finder onto
  the desktop itself are offered on the remote clipboard exactly as a Finder copy is (the
  `FileGroupDescriptorW` path), then, once the server has accepted the offer, xpnd sends a click at
  the drop point (so the window under the cursor has focus) and Ctrl+V. Explorer pastes them into the folder shown; Windows pulls the bytes
  from the Mac as it pastes. The offer stays until the next clipboard change, so a second Ctrl+V
  by the user pastes again. Nothing is typed into a Run box; the earlier "Also copy to" idea is
  dropped.
- **Drop folder housekeeping:** Settings → Remote Desktop: "Clear drop folders" never (default) /
  on disconnect / after 7 days; and a "Clear now" button.

## Non-goals (this round)

- A notch on terminal tabs; VNC in tabs; microphone; multi-monitor; session screenshots; Win+L,
  Alt+Tab, Print Screen buttons (easy to add later with the same key-sequence helper); moving
  files out of Windows to the Mac (the drive is read-write, so Windows can save into it — that is
  enough for now and needs no code).

## Anti-goals

- Redirecting anything but the drop folder. No home directory, no arbitrary path picker.
- The notch intercepting keystrokes meant for Windows, or keeping focus after a click.
- A desktop drop doing anything but offer the files on the remote clipboard, click, and Ctrl+V;
  never a typed command; nothing when the session isn't connected.
- Logging file names or paths at info level.

## Constraints

- FreeRDP 3.33.0 as vendored. Drive redirection: the `rdpdr` + `drive` channels are compiled in
  (`CHANNEL_DRIVE_CLIENT=ON`); the API is `freerdp_client_add_device_channel(settings, 3,
  ["drive", "xpnd", "<folder>"])` plus `FreeRDP_DeviceRedirection = TRUE`, applied before connect
  (`freerdp/client/cmdline.h`).
- Key sequences go through the existing `XPRDPView` keyboard path (scancodes via
  `freerdp_input_send_keyboard_event`), as `XPRDPSession` methods: `sendKeySequence:` taking an
  ordered list of (scancode, down/up) pairs; Ctrl+Alt+Del uses real Ctrl+Alt+Delete.
- Live display changes reuse the Display Control path (`viewSizeSettled` / monitor layout) for
  fit, and a desktop-resize request for fixed sizes; audio and clipboard toggles flip the session's
  runtime state (clipboard: stop/start the poll and send an empty format list; audio: FreeRDP has
  no runtime audio switch — the toggle reconnects with the changed setting, which the tooltip says).
- SwiftUI overlay on the RDP tab (`TerminalWorkspace` already overlays the ended bar); the notch
  is an `.overlay(alignment: .top)` that only hit-tests its own frame, so mouse events elsewhere
  reach the desktop. Tooltips via `.help`. The drop zone uses `.dropDestination(for: URL.self)`.
- `make test` green; nothing about session content, file names or paths logged; Conventional
  Commits; the branch builds on `feature/rdp-file-clipboard` (the pasteboard work it shares).

## Decided by the user

- The notch idea, hover fly-out with icon tooltips, the recommended button set, drop onto the notch
  landing in a Windows-visible folder, and a drop on the desktop pasting straight into the Explorer window there.

## My calls (the user can override)

- Notch placement top-centre, handle ~56×6 pt, fly-out row with 28 pt icons, pin button, ⌘⇧N.
- Session-only changes except Display's "Set as this connection's default".
- Drop folder per connection id under Application Support; drive name `xpnd`; default on.
- Desktop drop pastes via click + Ctrl+V into whatever has focus at the drop point (dropping on
  Notepad pastes nothing useful; the tooltip on the Files button explains both targets).
- Ctrl+Alt+Del sends real Ctrl+Alt+Delete.
- Audio toggle reconnects (FreeRDP limitation), stated in the tooltip.
- Info's latency comes from FreeRDP's network auto-detect when the server supports it, else "—".
- **Full screen** is the plain window full screen (`toggleFullScreen`): sidebar and tab bar stay,
  the desktop fills the detail column, the notch sits at the top of the desktop. An immersive mode
  that hides the chrome is a later feature.
- **Live toggles vs channels:** Display Control is always negotiated (`SupportDisplayControl`
  TRUE for every connection; `DynamicResolutionUpdate` only for fit), so Display switches live
  on servers that allow it and the Info popover says "fixed by the server" when the request is
  refused. Clipboard: on → off is live in both directions (the pasteboard poll stops, an empty
  format list is sent, and server format lists are ignored); off → on works live only if the
  channel was loaded at connect, otherwise the button says "Reconnect to enable" and reconnects
  with clipboard on for this session. Audio toggles reconnect, as already stated.
- **Drop-folder names:** `copyIn` copies each file under a *safe name* — ASCII letters, digits,
  space, `.`, `_`, `-`; everything else becomes `_`; a name that exists gets ` 2`, ` 3`, … — and
  returns the names it used, so the drive never holds a name Windows rejects.
- **Sequencing:** this is built on a new branch off `feature/rdp-file-clipboard` after that
  branch's clipboard work is committed; the notch work adds the runtime clipboard on/off switch
  to `XPRDPClipboard` if that work didn't, and the whole-desktop drag target and
  `sendKeySequence:` beside the keyboard code in `XPRDPView.m`/`XPRDPSession.m`.
- The drive channel is new attack surface: the plan includes a read of FreeRDP's
  `channels/drive/client/drive_file.c` path handling and a test that `copyIn` never writes outside
  the drop folder (a dropped symlink or `..` name).

## How it fits the code

- `RDPOptions`/`RDPSettings` gain `dropDrive: Bool` (default true) and `dropFolderCleanup:
  .never/.onDisconnect/.afterDays(7)` (global only).
  `RDPSettingMapping` emits `DeviceRedirection` and the drive device when `dropDrive` is on.
- `RDPDropFolder` (Swift, pure + file ops): the folder URL for a connection id, `copyIn(urls:)`
  (copies, returns the names; refuses nothing but reports failures), `count`, `clear`, cleanup
  policy application on disconnect/launch.
- `XPRDPSession` gains `sendKeySequence:`, `setClipboardSyncEnabled:`, `requestDesktopSize:` /
  `requestFit`, `connectionInfo` (desktop size, codec, latency if known, certificate subject and
  fingerprint from the last `decideCertificate`/connect, gateway). `XPRDPView` exposes the drop
  target for the whole desktop (`registerForDraggedTypes` for file URLs) and forwards to the host.
- `RDPNotch` (SwiftUI) in `Sources/xpnd/RemoteDesktop/`: the handle, fly-out, popovers, drop zone;
  it talks to `RDPHost` (which owns the session and the drop folder) through a small
  `RDPNotchActions` protocol so the view is testable with a fake.
- `TerminalWorkspace` overlays `RDPNotch` on `.remoteDesktop` tabs; ⌘⇧N is a hidden button like the
  other shortcuts; full screen uses `window.toggleFullScreen`.
- Editor "RDP options" → Files group: File drop drive toggle.
  Settings → Remote Desktop: File drop drive default, Clear drop folders policy, "Clear now".
- Docs: README (notch, file drop), DEVELOPMENT.md, CHANGELOG, CLAUDE.md findings.

## Tests

- Mapping: `dropDrive` on → `DeviceRedirection TRUE` and a drive device `xpnd` at the folder path;
  off → no device.
- `RDPDropFolder`: path per connection id; `copyIn` copies and returns names, keeps the source,
  rejects nothing; `clear`; cleanup policy decisions (`shouldClear(policy:lastUse:now:)` pure).
- Key sequences: a pure table from button → scancode sequence (`RDPKeySequence.ctrlAltDel`,
  `.winR`, `.ctrlV`, `.openDropFolder` = Win+R, type `\\tsclient\xpnd`, Enter) with tests that
  the sequences are balanced (every down has an up).
- `RDPNotch` view-model: button states from session state (connected/ended), audio cycle order,
  clipboard toggle, Display selection → the action called, a desktop drop → offer files, click at
  the point, Ctrl+V (nothing when disconnected), a notch drop → `copyIn`; with a fake
  `RDPNotchActions`.
- UI (hover, pin, popovers, full screen, actual drops) in the PR's manual checklist.

## Left to the builder

- Exact scancodes (FreeRDP's `RDP_SCANCODE_*` constants), how to type a string into the Run box
  (unicode input via `freerdp_input_send_unicode_keyboard_event`), the Display Control call for a
  fixed-size request, how to read the codec in use and auto-detect latency from the context.
- The notch visuals (material, corner radii, animation), popover layout, the count badge.
- Where the full-screen toggle lives (window-level) and keeping the notch reachable in full screen.
