# Bundled RDP — design

2026-11-04. Project 4 of xpnd: Windows desktops in tabs beside the SSH tabs, on FreeRDP.

## Intent

The user manages Windows servers (domain accounts, behind a VPN) alongside Linux hosts and wants
the full desktop inside xpnd's window, like Royal TSX, logging in with a domain user whose password
comes from 1Password — while leaving room for every other way people connect to RDP, because the
app isn't built for one person. FreeRDP was chosen over IronRDP: it's what the Mac RDP clients are
built on, it has the feature coverage (NLA, RD Gateway, clipboard, audio, dynamic resize), and it
ships its own Mac client view (`MRDPView`) that we can embed instead of writing a renderer.
IronRDP's cleaner stack lost on missing Swift bindings and H.264.

## Goals

- A third connection type, **RDP**, in the same tree as SSH and VNC: same folders, activation
  strings, colours, drag and drop, import/export, launcher, quick menu, double-click.
- Double-click / Connect / a typed activation string opens the desktop in a **tab** in the existing
  workspace, beside SSH tabs: same tab bar, Duplicate, Close, ⌘W, "Terminate N sessions?" on window
  close and Quit. The editor overlay works the same.
- Login: username as typed (`DOMAIN\user`, `user@domain`, or plain) plus an optional Domain field;
  password from the credential cascade (connection → folder → global; 1Password now, Bitwarden
  later). With no credential, or when the server rejects the login, a password sheet asks
  (username prefilled) — nothing is saved by xpnd.
- The desktop **resizes with the tab** (dynamic resolution) by default; Retina at 2× unless off.
- Options, each with a global default in Settings → Remote Desktop and a per-connection override:
  - Display: Resize to fit (default) / Fixed 1280×720, 1920×1080, 2560×1440, Custom W×H; when
    fixed, Scale to fit (default) or 1:1 with scrolling; colour depth 32 (default) / 16; Retina.
  - Clipboard sync (on). Audio: Play here (default) / Leave on remote / Off. Microphone (off).
  - Printers (off). Keyboard: ⌘ as Windows key (on).
  - Security: NLA (on). Certificate trust: unknown or changed certificate → a sheet with host,
    subject, issuer and SHA-256 fingerprint, Trust / Cancel; a changed certificate is marked as a
    warning. Trusted fingerprints are remembered per host:port by FreeRDP's known-hosts store under
    xpnd's Application Support (not the user's `~/.config/freerdp`).
  - Network: connection timeout (15 s), auto-reconnect on drop (on, 5 tries), performance preset
    Auto / LAN / Broadband (wallpaper, themes, font smoothing, animations).
  - Advanced: RD Gateway (host, port 443, credential: same as connection / its own ref), program
    to run on connect (alternate shell), console/admin session.
- Session end: a user-initiated disconnect or a clean server logoff closes the tab; a dropped or
  refused connection keeps the tab with "Disconnected: <reason>" and Close (and Reconnect — this
  one is worth it for RDP, where drops are common; my call).
- FreeRDP 3.33.0 (Apache 2.0) and OpenSSL are built from pinned sources by a script in `bin/` into
  a static universal library vendored as an xcframework the app links; their LICENSE/NOTICE files
  ship in the bundle. No Homebrew at runtime.

## Non-goals (this round)

- Multi-monitor, drive / USB / smart-card redirection, RemoteApp (RAIL), H.264/AVC codecs
  (RemoteFX and the progressive codec are in; H.264 needs OpenH264 and is a later upgrade),
  saving passwords in xpnd, Kerberos tickets, UDP transport, a Windows-App `.rdp` export.

## Anti-goals

- A password reaching the clipboard, the log, a file, or the terminal. RDP is the one place a
  secret leaves the "copied, never typed" model: it goes from the provider into FreeRDP's settings
  in memory, and nowhere else.
- The remote desktop reading a concealed clipboard item. Clipboard sync must never offer the
  remote any pasteboard item carrying xpnd's concealed marker or `org.nspasteboard.ConcealedType`,
  because SSH-session passwords sit on the pasteboard for 30 s.
- FreeRDP's own dialogs (the nibs in `client/Mac`) appearing — xpnd owns every prompt.
- Anything that needs the user to install FreeRDP, OpenSSL or Xcode command-line extras to run
  the release DMG.

## Constraints

- macOS 14+, Swift 6, SwiftPM. FreeRDP code is C/Objective-C, so it lives in a separate
  Objective-C SwiftPM target (`xpndRDP`) that links the vendored `FreeRDP.xcframework`
  (`.binaryTarget`); the Swift app target depends on `xpndRDP` and never imports FreeRDP headers.
- The xcframework is reproducible: `bin/build-freerdp.sh` downloads the pinned FreeRDP 3.33.0 and
  OpenSSL tarballs, verifies SHA-256 checksums written in the script, builds arm64 and x86_64 static
  libraries (`BUILD_SHARED_LIBS=OFF`, `WITH_CLIENT_MAC=ON`, channels: cliprdr, rdpsnd with the Mac
  backend, disp, rdpgfx; off: urbdrc, printers can stay on, video/H.264 off), merges them with
  `lipo` and `libtool -static`, and emits `vendor/FreeRDP.xcframework` (git-ignored) with the
  headers. `make freerdp` runs it; `bin/run.sh` and `make app` run it when the xcframework is
  missing. The script is the only place versions and checksums live.
- The hardened-runtime release must still notarize: static linking, no dylibs to sign; no new
  entitlements (no sandbox). Audio uses CoreAudio via FreeRDP's Mac `rdpsnd` backend.
- Security cadence: FreeRDP releases carry CVE fixes; CLAUDE.md gets a rule to bump the pin on
  security releases.
- The credential and secret rules of CLAUDE.md apply unchanged; the pasteboard rule above is new.

## Decided by the user

- FreeRDP; full desktop in a tab beside SSH tabs; dynamic resize; domain user + password from
  1Password by default, other login ways kept open; the option set above ("any other options an RDP
  app would normally have" — the list is my reading of that); servers are behind a VPN, so NLA
  and certificate trust are front and centre and the gateway lives under Advanced.

## My calls (the user can override)

- `MRDPView` from FreeRDP's Mac client is the session view; its C callbacks are replaced with
  xpnd's after the client context is created, so certificate, password and logon-error prompts are
  xpnd sheets. The rest of `client/Mac` (its dialogs, `main.m`, the `cli`) is not used.
- ⌘ on pick does nothing for an RDP connection (no sudo equivalent).
- Reconnect button on a disconnected tab; "Disconnected: <reason>" uses FreeRDP's error text
  mapped to plain words for the common codes (logon failed, access denied, server refused,
  connection timed out, certificate rejected, network lost).
- Per-connection options are a single `rdp:` block in `connections.yaml` holding only the keys the
  user changed; missing keys inherit the global defaults from Settings (stored in UserDefaults like
  the other settings). Import/export carries the block; the import preview lists RDP connections
  with their host and gateway.
- The `TerminalHost` seam is reused: an `RDPHost` implements `view`, `onExit`, `terminate()` and a
  no-op `apply`; `TerminalSessions`, the tab bar and close/quit code don't change except a tab icon
  per session kind and the ended bar's wording. The workspace's 8 pt padding does not apply to an
  RDP tab (the desktop fills it).
- Keyboard: ⌘ maps to the Windows key by default because Mac users expect ⌘C/⌘V to work in Windows
  apps the way Windows App does it: with the option on, ⌘ acts as Ctrl for the common edit
  shortcuts (⌘C/⌘V/⌘X/⌘Z/⌘A) and as the Windows key otherwise — builder to confirm what
  `MRDPView`'s keyboard mapping already does and extend only if needed.
- Retina: desktop size is the view's size in backing pixels when Retina is on, points when off.
- **Snippets and activation strings inside an RDP tab** (decided by the user): a keyword typed into
  the Windows desktop expands by **typing keystrokes** into it, exactly as xpnd already does for
  Windows App and Royal TSX — never by paste, which would go to the remote clipboard. A typed
  connection string opens another tab. So `terminalHasFocus` covers RDP hosts too, and the
  keystroke sender's "type instead of paste" decision gains an input for "the key window's focused
  session is RDP" alongside the bundle-id list.
- **Password lifetime:** the login password lives in the session (the Objective-C side) for the
  tab's lifetime and is zeroed when the tab closes, so FreeRDP's auto-reconnect and the Reconnect
  button are instant and need no Touch ID; a login the server rejects reconnects with what the
  password sheet returns. CLAUDE.md's secret rule gets this exception spelled out.
- **Microphone:** dropped this round (needs `com.apple.security.device.audio-input`, a usage
  string and the `audin` channel); audio playback stays.
- **Build prerequisite:** `make freerdp` must run before any `swift build`, `swift test` or Xcode
  open on a fresh clone — SwiftPM can't load a manifest whose `.binaryTarget` path is missing. The
  Makefile's `build`/`test` targets depend on it and the README says so; a checksum-verified
  prebuilt download is a later improvement.

## How it fits the code

- `ConnectionType` gains `.rdp`; `Connection` gains `domain: String?` and `rdp: RDPOptions?`
  (Codable, only set keys encoded). `RDPSettings` (global defaults) in `AppSettings.remoteDesktop`.
  `RDPOptions.resolved(over: RDPSettings) -> RDPSessionConfig` is the one merge.
- Credentials: `library.loginCredential(for:)` and `loginUser(for:)` already cascade; RDP uses the
  login credential's password (fetched by `OnePasswordProvider.password(for:)`) and the gateway's
  credential when set. The fetch happens in `ConnectionService` before the tab opens, inside the
  engine claim like the SSH key fetch; the password is handed to the host and dropped.
- `LaunchPlanner` isn't involved: `ConnectionService.plan(for:)` returns a new `.rdpTab(config)`
  for `.rdp` connections before the SSH branch, as `.openURL` does for VNC; the typed-string and
  launcher paths therefore open a tab too. `openTab` grows a second shape (or a small enum) for RDP.
- `xpndRDP` (Objective-C target, `Sources/xpndRDP/`): `XPRDPSession` wraps context creation
  (`freerdp_client_context_new` with the Mac client entry points), applies an `XPRDPConfig`
  (plain ObjC object mirroring `RDPSessionConfig`) to `rdpSettings`, installs xpnd's callbacks
  (`VerifyCertificateEx`, `VerifyChangedCertificateEx`, `Authenticate`, `LogonErrorInfo`,
  `PostDisconnect`), starts/stops the client thread, and exposes the `MRDPView`, delegate calls
  for certificate decisions / password prompts (answered asynchronously from Swift sheets; the
  FreeRDP thread blocks on a semaphore until then), and disconnect with reason. The clipboard
  bridge filters concealed items before `cliprdr` sees them.
- `RDPHost: TerminalHost` (Swift, `Sources/xpnd/Terminal/`) owns an `XPRDPSession`; its delegate
  methods present the sheets on the main window and map errors to the ended-bar text; Reconnect
  creates a new session with the same config.
- Editor: `ConnectionEditorView` shows RDP fields when type is `.rdp` (host, port 3389, username,
  domain, credential picker as today) plus an "RDP options" disclosure with the per-connection
  overrides grouped Display / Sound & Clipboard / Security / Network / Advanced, each control
  showing "Default (…)" until changed. Settings gets a "Remote Desktop" tab with the same groups.
- Docs: DEVELOPMENT.md (new component + the build script), README (RDP in Connections, build
  prerequisites: CMake for `make freerdp`), CHANGELOG, CLAUDE.md (findings + the pin-bump rule).

## Tests

- Model: `RDPOptions` encode only set keys; `resolved(over:)` merges; YAML round trip of an RDP
  connection with domain, gateway and options; the import preview lists RDP rows.
- Mapping: `RDPSessionConfig → [FreeRDP setting name: value]` is a pure Swift function (or the ObjC
  config object has a testable description) covering every option in Goals, including dynamic vs
  fixed resolution, Retina scaling, audio modes, gateway on/off, NLA, performance presets.
- Routing: `ConnectionService` opens an RDP tab for `.rdp` (no executor, no SSH build), fetches the
  password through the fake provider first, and opens nothing when the provider fails (with the HUD
  message); the typed-string path does the same.
- Clipboard: the concealment filter is a pure function over pasteboard types; tests cover the
  xpnd marker and `org.nspasteboard.ConcealedType`.
- Error mapping: FreeRDP error codes → ended-bar text.
- Build script: a dry-run mode that prints the pinned versions and checksums; `make freerdp` is a
  manual step in the PR checklist. UI (sheets, resize, audio) goes in the PR's manual checklist.

## Left to the builder

Known gaps in FreeRDP 3.33's `MRDPView` (verified by the design review) that the subclass must
close: no DISP/dynamic-resolution support, no backing-scale handling, a client thread that does one
`freerdp_connect` with no reconnect loop, `AuthenticateEx` not re-asked after a logon failure, and
a clipboard poll that reads only the first pasteboard item's `public.utf8-plain-text`. `rdpStart:`,
`keyDown:` and `onPasteboardTimerFired:` are public and the ivars protected, so subclassing works.

- Exact FreeRDP 3.33 setting keys (`FreeRDP_ServerHostname`, `FreeRDP_DynamicResolutionUpdate`,
  `FreeRDP_GatewayHostname`, …), the client entry points, how `MRDPView` handles resize and
  backing scale, and how its clipboard sync is hooked for the concealment filter.
- CMake options for a minimal static build, the OpenSSL version to pin, and how long the build
  takes (document it).
- The ObjC ↔ Swift bridging shape (a small protocol for the delegate; Swift 6 isolation rules for
  callbacks that arrive on FreeRDP's thread).
- Sheet visuals and the exact "Disconnected" wording per code.
