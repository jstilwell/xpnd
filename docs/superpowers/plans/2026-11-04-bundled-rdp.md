# Bundled RDP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows desktops open as tabs beside the SSH tabs, on a vendored static FreeRDP, with domain login from the credential cascade, dynamic resize, xpnd-owned certificate/password prompts, and per-connection options over global defaults.

**Architecture:** `bin/build-freerdp.sh` turns pinned FreeRDP + OpenSSL sources into `vendor/FreeRDP.xcframework`; a new Objective-C SwiftPM target `xpndRDP` wraps FreeRDP's Mac client (`MRDPView` subclass + a session object that applies settings by name, installs xpnd's callbacks and reports disconnects). Swift never imports FreeRDP: `RDPHost` implements the existing `TerminalHost` seam, `ConnectionService` grows an `.rdpTab` path that fetches the password first, and a pure `RDPSessionConfig → [RDPSetting]` mapping carries every option, so the option logic is unit-tested without a server.

**Tech Stack:** Swift 6, SwiftUI/AppKit, Objective-C (ARC) target, SwiftPM `binaryTarget`, FreeRDP 3.33.0, OpenSSL 3.5.9, CMake ≥ 3.13, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-04-bundled-rdp-design.md`

## Global Constraints

- Pins live only in `bin/build-freerdp.sh`: FreeRDP `3.33.0` from `https://pub.freerdp.com/releases/freerdp-3.33.0.tar.xz`, SHA-256 `9cea38e972e3775e1ce83b30e9ae0cbf8d00af1c708c640e6244fc81bdb1e08b`; OpenSSL `3.5.9` from `https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz`, SHA-256 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`. A checksum mismatch aborts the build.
- Output `vendor/FreeRDP.xcframework` (git-ignored), universal (arm64 + x86_64), static only (`BUILD_SHARED_LIBS=OFF`), macOS deployment target 14.0, with headers for `freerdp`, `winpr`, `freerdp/client` and the Mac client (`MRDPView.h`, `mfreerdp.h`, `mf_client.h`, `Keyboard.h`, `Clipboard.h`, `MRDPCursor.h`) copied from the source tree. FreeRDP's and OpenSSL's `LICENSE` files land in `vendor/licenses/` and ship in the bundle as `FreeRDP License.txt` and `OpenSSL License.txt`.
- CMake switches: `-DWITH_CLIENT_MAC=ON -DWITH_CLIENT_SDL=OFF -DWITH_SERVER=OFF -DWITH_SAMPLE=OFF -DWITH_MANPAGES=OFF -DWITH_FFMPEG=OFF -DWITH_SWSCALE=OFF -DWITH_OPENH264=OFF -DWITH_X11=OFF -DWITH_PCSC=OFF -DWITH_KRB5=OFF -DWITH_FUSE=OFF -DWITH_WINPR_TOOLS=OFF -DBUILD_TESTING=OFF -DCHANNEL_URBDRC=OFF -DCHANNEL_AUDIN=OFF` plus `OPENSSL_ROOT_DIR` pointing at the static OpenSSL; `WITH_MACAUDIO` stays on (default); clipboard, rdpsnd, disp, rdpgfx, rdpdr/printer channels stay on. If a JSON library is demanded, pass `-DWITH_WINPR_JSON=OFF`.
- SwiftPM: `.binaryTarget(name: "FreeRDP", path: "vendor/FreeRDP.xcframework")`; `.target(name: "xpndRDP", dependencies: ["FreeRDP"], linkerSettings: [.linkedFramework("Cocoa"), .linkedFramework("IOKit"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox")])`; the `xpnd` target depends on `xpndRDP`; only files under `Sources/xpndRDP/` may include FreeRDP headers.
- The password goes from the provider into the session object's memory and nowhere else; zeroed on close; never logged. Clipboard sync never offers the remote an item carrying `org.nspasteboard.ConcealedType` or xpnd's `SecretClipboard` tag type.
- Copy: tab ended bar "Disconnected: <reason>" with buttons "Reconnect" and "Close"; reasons: "logon failed", "access denied", "the server refused the connection", "the connection timed out", "the certificate was rejected", "the network connection was lost", "cancelled", otherwise FreeRDP's error name. Certificate sheet title "Trust this certificate?" (unknown) / "This certificate has changed" (changed), buttons "Trust" / "Cancel". Password sheet title "Password for <user>@<host>", buttons "Connect" / "Cancel". Settings tab "Remote Desktop"; editor disclosure "RDP options"; unchanged option controls show "Default (<value>)".
- Defaults (global): Resize to fit; fixed 1920×1080 when switched to Fixed; scale to fit; colour depth 32; Retina on; clipboard on; audio Play here; printers off; ⌘ as Windows key on; NLA on; timeout 15 s; auto-reconnect on, 5 tries; performance Auto; gateway off (port 443); alternate shell empty; console off.
- `make freerdp` must precede `swift build`/`swift test` on a fresh clone; `make build`, `make test`, `make app`, and `bin/run.sh` run it when the xcframework is missing.
- No new entitlements. Conventional Commits; commit only compiling code; never `--no-verify`; never run `op`. Branch `feature/bundled-rdp`.

## Review Focus

1. The server is unreachable or times out: the tab ends with "Disconnected: the connection timed out" and Reconnect retries with the same password without Touch ID. (Test in Task 5: error-text mapping for `FREERDP_ERROR_CONNECT_TRANSPORT_FAILED`/`FREERDP_ERROR_CONNECT_FAILED`; Task 4 test: a session stopped before connecting reports a disconnect exactly once.)
2. A wrong password: the password sheet appears with the username prefilled; Cancel ends the tab with "Disconnected: cancelled"; a new password reconnects. (Task 5 test: the `RDPHost` delegate path with a fake session; Task 4: `authenticate` callback suspends the FreeRDP thread until answered.)
3. A changed certificate (re-imaged server): the sheet warns, Cancel ends the tab with "the certificate was rejected", Trust remembers it under xpnd's config path, not `~/.config/freerdp`. (Task 4 test: `configPath` setting is applied; Task 5 test: certificate decision → `.accept`/`.reject` mapping.)
4. An SSH password sits concealed on the pasteboard while an RDP tab is open: the remote must never see it. (Task 4 test: `XPRDPClipboardFilter.shouldOffer` for the two marker types.)
5. Resizing the window continuously: the desktop follows the final size without flooding the server. (Task 4: resize requests coalesce to one per 200 ms idle — a test on the coalescer's pure timing policy.)

---

### Task 1: FreeRDP build chain, binary target, and the `xpndRDP` target skeleton

**Files:**
- Create: `bin/build-freerdp.sh`
- Modify: `Makefile` (`freerdp` target; `build`, `test`, `app` depend on it), `bin/run.sh` (run `make freerdp` when `vendor/FreeRDP.xcframework` is missing), `.gitignore` (`/vendor/`), `Package.swift`
- Create: `Sources/xpndRDP/include/xpndRDP.h` (umbrella), `Sources/xpndRDP/include/XPRDPVersion.h`, `Sources/xpndRDP/XPRDPVersion.m`
- Test: `Tests/xpndTests/RDPLinkTests.swift`

**Interfaces:**
- Produces: `vendor/FreeRDP.xcframework`; `make freerdp`; `bin/build-freerdp.sh [--print]` (`--print` prints the two version/URL/SHA lines and exits 0 without downloading); ObjC `@interface XPRDPVersion : NSObject + (NSString *)freerdpVersion;` returning `freerdp_get_version_string()`.

- [ ] **Step 1: Write the failing test**
  ```swift
  import Testing
  import xpndRDP
  struct RDPLinkTests {
      @Test func linksFreeRDP() { #expect(XPRDPVersion.freerdpVersion().hasPrefix("3.33.0")) }
  }
  ```
- [ ] **Step 2: Run** `swift test --filter RDPLinkTests` — expected: manifest/compile failure (no `xpndRDP`).
- [ ] **Step 3: Write `bin/build-freerdp.sh`** (bash, `set -euo pipefail`): work dir `vendor/build/`; download both tarballs with `curl -L`, verify with `shasum -a 256 -c`; build OpenSSL twice (`./Configure darwin64-arm64-cc` / `darwin64-x86_64-cc`, `no-shared no-tests no-apps`, `--prefix=vendor/build/openssl-<arch>`, `-mmacosx-version-min=14.0`); build FreeRDP twice with the Global Constraints switches, `-DCMAKE_OSX_ARCHITECTURES=<arch> -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_INSTALL_PREFIX=vendor/build/freerdp-<arch>` and `cmake --build … --target install`; for each arch merge every `.a` under both prefixes with `libtool -static -o libFreeRDP-<arch>.a`; `lipo -create` the two into `libFreeRDP.a`; assemble `Headers/` (installed `freerdp`, `winpr` includes + the Mac client headers from the source tree); `xcodebuild -create-xcframework -library libFreeRDP.a -headers Headers -output vendor/FreeRDP.xcframework`; copy the licences. Print the elapsed time at the end. `--print` short-circuits before any download. Add a header comment with the pin-bump procedure (edit URL + SHA, run `make freerdp`).
- [ ] **Step 4: Makefile and run.sh**: `freerdp: vendor/FreeRDP.xcframework` / `vendor/FreeRDP.xcframework: bin/build-freerdp.sh ; bash bin/build-freerdp.sh`; `build test app: freerdp` prerequisites; the `app` recipe copies `vendor/licenses/*.txt` into `Contents/Resources/`. `bin/run.sh`: before `make run`, `[ -d vendor/FreeRDP.xcframework ] || make freerdp`.
- [ ] **Step 5: Run** `make freerdp` — expected: `vendor/FreeRDP.xcframework/Info.plist` lists `macos-arm64_x86_64`; `lipo -info` on the library shows both; record the wall time in the script header comment.
- [ ] **Step 6: `Package.swift` and the skeleton** per Global Constraints; `XPRDPVersion.m` includes `<freerdp/version.h>` (or `<freerdp/freerdp.h>`) and returns `[NSString stringWithUTF8String:freerdp_get_version_string()]`.
- [ ] **Step 7: Run** `swift test --filter RDPLinkTests` — expected: PASS. Then `make app` — bundle builds and `codesign -v` passes.
- [ ] **Step 8: Commit** `build: vendor FreeRDP 3.33.0 as a static xcframework` (script, Makefile, run.sh, .gitignore) and `feat(rdp): xpndRDP target linked to FreeRDP` (Package.swift, sources, test).

### Task 2: Connection model — RDP type, domain, options, global defaults

**Files:**
- Modify: `Sources/xpnd/Connections/Connection.swift` (`ConnectionType.rdp`, `Connection.domain`, `Connection.rdp`)
- Create: `Sources/xpnd/RemoteDesktop/RDPOptions.swift` (`RDPOptions`, `RDPSettings`, `RDPSessionConfig`, `resolved(over:)`)
- Modify: `Sources/xpnd/App/AppSettings.swift` (`remoteDesktop: RDPSettings`, key `remoteDesktop`)
- Modify: every `switch` over `ConnectionType` the compiler flags (sidebar/launcher symbols: RDP uses `"pc"`; `LaunchPlanner`/`ConnectionService` untouched here), `Sources/xpnd/Connections/ConnectionImport.swift` (`PreviewRow.address` for RDP: `user@host:port`, plus `gateway: String?` shown as "via <gateway>")
- Test: `Tests/xpndTests/RDPOptionsTests.swift`, additions to `ConnectionYAMLTests` / `ConnectionImportTests`

**Interfaces:**
- Produces:
  ```swift
  enum ConnectionType: String, Codable, Sendable { case ssh, vnc, rdp }   // defaultPort: 22 / 5900 / 3389
  // Connection gains:
  var domain: String?
  var rdp: RDPOptions?
  struct RDPOptions: Codable, Hashable, Sendable {   // every field optional; only set keys encode
      enum Display: Codable, Hashable, Sendable { case fit, fixed(width: Int, height: Int) }
      enum Audio: String, Codable, Sendable { case local, remote, off }
      enum Performance: String, Codable, Sendable { case auto, lan, broadband }
      struct Gateway: Codable, Hashable, Sendable { var host: String; var port: Int = 443; var credential: CredentialRef? }  // nil credential = same as connection
      var display: Display?; var scaleToFit: Bool?; var colorDepth: Int?; var retina: Bool?
      var clipboard: Bool?; var audio: Audio?; var printers: Bool?; var commandAsWindowsKey: Bool?
      var nla: Bool?; var timeoutSeconds: Int?; var autoReconnect: Bool?; var reconnectTries: Int?; var performance: Performance?
      var gateway: Gateway?; var alternateShell: String?; var consoleSession: Bool?
  }
  struct RDPSettings: Codable, Hashable, Sendable { /* same fields, non-optional, with the Global Constraints defaults */ static let standard: RDPSettings }
  struct RDPSessionConfig: Equatable, Sendable { /* RDPSettings' fields + host, port, username, domain, gateway */ }
  extension RDPOptions { func resolved(over defaults: RDPSettings, host: String, port: Int, username: String?, domain: String?) -> RDPSessionConfig }
  ```
  `RDPOptions.none` (all nil) resolves to the defaults; `Connection.rdp == nil` behaves as `.none`.

- [ ] **Step 1: Write the failing tests**
  ```swift
  @Test func emptyOptionsResolveToDefaults()   // RDPOptions().resolved(over: .standard, host: "h", port: 3389, username: "u", domain: "D") == config with every default and display == .fit
  @Test func setOptionsOverrideDefaults()      // display .fixed(1280,720), audio .off, gateway host "gw" → resolved config carries them, others default
  @Test func onlySetKeysEncode()               // JSON of RDPOptions(audio: .off) decodes back equal and contains only "audio"
  @Test func rdpConnectionRoundTripsThroughYAML()  // Connection(type: .rdp, host: "win", domain: "CORP", rdp: …) → ConnectionYAML encode → decode equal; type encodes as "rdp"
  @Test func defaultPortIs3389()
  @Test func importPreviewShowsRDPAddressAndGateway()  // PreviewRow.address == "CORP\\me@win:3389", gateway == "gw"
  ```
- [ ] **Step 2: Run** `swift test --filter 'RDPOptionsTests|ConnectionYAMLTests|ConnectionImportTests'` — expected: compile failure.
- [ ] **Step 3: Implement** per Interfaces; `AppSettings.remoteDesktop` follows the `terminal` pattern.
- [ ] **Step 4: Run** `swift test` — expected: all pass (existing switches updated).
- [ ] **Step 5: Commit** `feat(connections): RDP connection type with options and global defaults`.

### Task 3: Config → FreeRDP settings mapping (pure Swift)

**Files:**
- Create: `Sources/xpnd/RemoteDesktop/RDPSettingMapping.swift`
- Test: `Tests/xpndTests/RDPSettingMappingTests.swift`

**Interfaces:**
- Consumes: `RDPSessionConfig` (Task 2).
- Produces:
  ```swift
  /// One FreeRDP setting by its `FreeRDP_<Name>` key and the text FreeRDP parses for that key's type.
  struct RDPSetting: Equatable, Sendable { let name: String; let value: String }
  extension RDPSessionConfig {
      /// Everything but the password, in a stable order; `configPath` is xpnd's Application Support/xpnd/freerdp.
      func freerdpSettings(configPath: String, viewPixelSize: (width: Int, height: Int)) -> [RDPSetting]
  }
  ```
  Keys (verify each against the built headers in `vendor/FreeRDP.xcframework/…/Headers/freerdp/settings_types.h`; use the exact enum names without the `FreeRDP_` prefix stripped — the ObjC side resolves them with `freerdp_settings_get_key_for_name`): `FreeRDP_ServerHostname`, `FreeRDP_ServerPort`, `FreeRDP_Username`, `FreeRDP_Domain`, `FreeRDP_DesktopWidth`/`Height`, `FreeRDP_DynamicResolutionUpdate` + `FreeRDP_SupportDisplayControl` (fit), `FreeRDP_SmartSizing` (fixed + scale), `FreeRDP_ColorDepth`, `FreeRDP_DesktopScaleFactor`/`FreeRDP_DeviceScaleFactor` (Retina: 200/180 vs 100/100), `FreeRDP_RedirectClipboard`, `FreeRDP_AudioPlayback`/`FreeRDP_RemoteConsoleAudio`, `FreeRDP_RedirectPrinters`, `FreeRDP_NlaSecurity`, `FreeRDP_TcpConnectTimeout` (ms), `FreeRDP_AutoReconnectionEnabled`/`FreeRDP_AutoReconnectMaxRetries`, `FreeRDP_ConnectionType` (auto 7, lan 6, broadband 4) and the performance flags for lan/broadband (`FreeRDP_DisableWallpaper`, `FreeRDP_DisableThemes`, `FreeRDP_DisableFullWindowDrag`, `FreeRDP_DisableMenuAnims`, `FreeRDP_AllowFontSmoothing`), `FreeRDP_GatewayEnabled`/`FreeRDP_GatewayHostname`/`FreeRDP_GatewayPort`/`FreeRDP_GatewayUseSameCredentials`, `FreeRDP_AlternateShell`, `FreeRDP_ConsoleSession`, `FreeRDP_ConfigPath`, `FreeRDP_SupportGraphicsPipeline` + `FreeRDP_RemoteFxCodec` + `FreeRDP_GfxProgressive` (on), `FreeRDP_GfxH264`/`FreeRDP_GfxAVC444` (off). Desktop size for `.fit` = `viewPixelSize` (or its half when Retina is off); for `.fixed` = the fixed size.

- [ ] **Step 1: Write the failing tests** (assert exact `RDPSetting` entries, using a helper `settings.first { $0.name == "FreeRDP_…" }?.value`)
  ```swift
  @Test func fitUsesViewSizeAndDynamicResolution()   // viewPixelSize 2880×1800, retina on → DesktopWidth "2880", DynamicResolutionUpdate "TRUE", SupportDisplayControl "TRUE", DesktopScaleFactor "200"
  @Test func retinaOffHalvesTheViewSize()            // → "1440"×"900", scale factors "100"
  @Test func fixedWithScaleUsesSmartSizing()         // .fixed(1280,720), scaleToFit true → DesktopWidth "1280", SmartSizing "TRUE", DynamicResolutionUpdate "FALSE"
  @Test func audioModes()                            // local → AudioPlayback TRUE, RemoteConsoleAudio FALSE; remote → FALSE/TRUE; off → FALSE/FALSE
  @Test func gatewayOnOff()                          // nil → GatewayEnabled FALSE; set → TRUE + hostname/port, UseSameCredentials TRUE when credential nil
  @Test func performancePresets()                    // lan → ConnectionType "6", DisableWallpaper "FALSE"; broadband → "4", DisableWallpaper "TRUE"; auto → "7"
  @Test func securityAndMisc()                       // nla → NlaSecurity, timeout 15 → TcpConnectTimeout "15000", reconnect 5, ConsoleSession, AlternateShell, ConfigPath, H264 off
  @Test func neverContainsAPassword()                // no name contains "Password"
  ```
- [ ] **Step 2: Run** `swift test --filter RDPSettingMappingTests` — expected: compile failure.
- [ ] **Step 3: Implement** the mapping as one function returning an array literal built in sections.
- [ ] **Step 4: Run** `swift test --filter RDPSettingMappingTests` — expected: 8 passed.
- [ ] **Step 5: Commit** `feat(rdp): map session config to FreeRDP settings`.

### Task 4: `xpndRDP` — session object, view subclass, callbacks, clipboard filter

**Files:**
- Create: `Sources/xpndRDP/include/XPRDPSession.h`, `Sources/xpndRDP/XPRDPSession.m`, `Sources/xpndRDP/XPRDPView.h` (+ `.m`), `Sources/xpndRDP/include/XPRDPClipboardFilter.h` (+ `.m`), `Sources/xpndRDP/XPRDPResizeCoalescer.h` (+ `.m`, exposed in `include/` for the test)
- Modify: `Sources/xpndRDP/include/xpndRDP.h`, `Sources/xpnd/Credentials/SecretClipboard.swift` (named `secretType` constant, if none exists)
- Test: `Tests/xpndTests/XPRDPSessionTests.swift`

**Interfaces:**
- Consumes: FreeRDP headers only here.
- Produces (ObjC, nullability annotated, `NS_ASSUME_NONNULL`):
  ```objc
  typedef NS_ENUM(NSInteger, XPRDPCertificateKind) { XPRDPCertificateKindUnknown, XPRDPCertificateKindChanged };
  @interface XPRDPCertificate : NSObject   // host, port, subject, issuer, fingerprintSHA256 (NSString), kind
  @protocol XPRDPSessionDelegate <NSObject>
  - (void)session:(XPRDPSession *)s decideCertificate:(XPRDPCertificate *)c completion:(void (^)(BOOL trust))completion;  // called on main
  - (void)session:(XPRDPSession *)s requestPasswordForUser:(NSString *)user host:(NSString *)host completion:(void (^)(NSString * _Nullable password))completion;
  - (void)session:(XPRDPSession *)s didDisconnectWithErrorName:(NSString * _Nullable)errorName;  // nil = clean; names like "FREERDP_ERROR_CONNECT_LOGON_FAILURE"; main thread
  - (void)sessionDidConnect:(XPRDPSession *)s;
  @end
  @interface XPRDPSession : NSObject
  - (instancetype)initWithSettings:(NSArray<NSArray<NSString *> *> *)settings  // [[name, value], …]
                          password:(NSString *)password gatewayPassword:(NSString * _Nullable)gatewayPassword
                          delegate:(id<XPRDPSessionDelegate>)delegate;
  @property (readonly) NSView *view;          // the XPRDPView, created with the session
  - (BOOL)start;                              // applies settings, starts the client thread; NO if the context couldn't be created
  - (void)stop;                               // aborts/disconnects, zeroes the password, no delegate callback after it returns
  - (void)reconnect;                          // stop + start with the same settings and password
  - (nullable NSString *)stringSettingNamed:(NSString *)name;  // test hook: freerdp_settings_get_string by name
  - (BOOL)boolSettingNamed:(NSString *)name;                   // test hook
  @end
  @interface XPRDPClipboardFilter : NSObject
  + (BOOL)shouldOfferPasteboardTypes:(NSArray<NSString *> *)types;   // NO when types contain "org.nspasteboard.ConcealedType" or "com.jessestilwell.xpnd.secret"
  @end
  @interface XPRDPResizeCoalescer : NSObject
  - (instancetype)initWithIdleInterval:(NSTimeInterval)seconds handler:(void (^)(CGSize))handler;
  - (void)noteSize:(CGSize)size;              // handler fires once with the last size after `seconds` without a new size
  @end
  ```
  Behaviour: `start` creates the context via `freerdp_client_context_new` with the Mac entry points (`RdpClientEntry`), applies each setting with `freerdp_settings_set_value_for_name` (fail `start` on a NO), sets `FreeRDP_Password` (and `FreeRDP_GatewayPassword`), replaces `instance->VerifyCertificateEx`, `VerifyChangedCertificateEx`, `AuthenticateEx`, `LogonErrorInfo`, `PostDisconnect` with xpnd's C functions (which find the session through `mfContext`'s `view` → `XPRDPView.session`), sets `mfc->view` to an `XPRDPView` it owns (`view_ownership = FALSE`), then `freerdp_client_start`. The certificate/password callbacks run on FreeRDP's thread: dispatch to main, block on a semaphore until the completion runs, return the decision (FreeRDP's contract: `1` = accept and store, `2` = accept for this session only, `0` = reject; Trust returns `1`). `PostDisconnect` reports `freerdp_get_last_error_name(context)` (nil when `freerdp_get_last_error` is 0) to the delegate on main, exactly once per start. `XPRDPView: MRDPView` adds: backing-scale-aware mouse coordinates, `viewDidChangeBackingProperties`, a `setFrameSize:` override that feeds the coalescer, which sends a display-control layout (`DISP` via the client's `disp` context when `DynamicResolutionUpdate` is on), the pasteboard-timer override that consults `XPRDPClipboardFilter` before offering formats, and ⌘-as-Windows-key handling if `Keyboard.m` doesn't already map it. `SecretClipboard`'s tag type must be exposed as a constant the Swift side and this filter agree on (add `static let secretType = "com.jessestilwell.xpnd.secret"` to `SecretClipboard` if it has no named type yet, and use it when copying).

- [ ] **Step 1: Write the failing tests** (no server; nothing connects)
  ```swift
  @MainActor @Test func settingsAreAppliedByName() {
      let s = XPRDPSession(settings: [["FreeRDP_ServerHostname", "win.example"], ["FreeRDP_NlaSecurity", "FALSE"]], password: "p", gatewayPassword: nil, delegate: FakeDelegate())
      #expect(s.prepare())  // see Step 3: `prepare` creates the context and applies settings without starting the thread
      #expect(s.stringSettingNamed("FreeRDP_ServerHostname") == "win.example")
      #expect(!s.boolSettingNamed("FreeRDP_NlaSecurity"))
  }
  @MainActor @Test func unknownSettingNameFailsPrepare()
  @Test func clipboardFilterHidesConcealedItems() { #expect(!XPRDPClipboardFilter.shouldOfferPasteboardTypes(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])); #expect(!…(["com.jessestilwell.xpnd.secret"])); #expect(XPRDPClipboardFilter.shouldOfferPasteboardTypes(["public.utf8-plain-text"])) }
  @Test func resizeCoalescerFiresOnceWithLastSize() async  // noteSize 3 times within 50 ms, idle 100 ms → handler once with the last size
  @MainActor @Test func stopBeforeStartReportsNothing()      // stop on a prepared-but-not-started session → delegate never called
  ```
- [ ] **Step 2: Run** `swift test --filter XPRDPSessionTests` — expected: compile failure.
- [ ] **Step 3: Implement**; add `- (BOOL)prepare;` (context + settings, idempotent) that `start` calls first, so tests can inspect settings without a thread.
- [ ] **Step 4: Run** `swift test` — expected: all pass; `swift build` warning-free in `Sources/xpndRDP`.
- [ ] **Step 5: Commit** `feat(rdp): FreeRDP session with xpnd's prompts, resize and clipboard guard`.

### Task 5: `RDPHost`, tab kinds, sheets, error text, and the connect path

**Files:**
- Create: `Sources/xpnd/RemoteDesktop/RDPHost.swift`, `Sources/xpnd/RemoteDesktop/RDPErrorText.swift`, `Sources/xpnd/RemoteDesktop/RDPPrompts.swift` (certificate + password sheets as SwiftUI views presented from the host)
- Modify: `Sources/xpnd/Terminal/TerminalSession.swift` (`TerminalSession.kind: Kind { case terminal, remoteDesktop }`, `State.disconnected(String)`, `TerminalHost.reconnect()` with a default no-op via extension), `Sources/xpnd/Terminal/TerminalWorkspace.swift` (icon per kind; ended bar for `.disconnected`: "Disconnected: <reason>" + Reconnect + Close; no 8 pt padding for `.remoteDesktop`), `Sources/xpnd/Connections/ConnectionService.swift` (`.rdpTab` path), `Sources/xpnd/App/AppDelegate+Connections.swift`, `Sources/xpnd/Main/MainWindowController.swift` (`openTab` takes a `TabRequest` enum)
- Test: `Tests/xpndTests/RDPErrorTextTests.swift`, additions to `ConnectionServiceTests` and `TerminalSessionsTests`

**Interfaces:**
- Consumes: `XPRDPSession` + delegate (Task 4), `RDPSessionConfig.freerdpSettings` (Task 3), `TerminalSessions.open` (existing).
- Produces:
  ```swift
  enum TabRequest { case terminal(SSHCommand), remoteDesktop(RDPSessionConfig, password: String, gatewayPassword: String?) }
  // ConnectionService: openTab closure type becomes @MainActor (TabRequest, Connection) -> Void; plan(for:) returns .rdpTab(config) for .rdp before the SSH branch; connect fetches the login (and gateway) password through the provider inside the claim, then openTab(.remoteDesktop(…)); a provider error → notify(message), no tab.
  enum RDPErrorText { static func reason(forErrorName name: String?) -> String }  // Global Constraints copy; nil → "the server closed the session"
  final class RDPHost: TerminalHost, XPRDPSessionDelegate { init(config:, password:, gatewayPassword:, presentIn: () -> NSWindow?) ; var onDisconnect: ((String?) -> Void)? }
  // TerminalSessions.open gains `kind:`; an RDP session ends via `disconnected(reason)` → State.disconnected; clean (nil error after a user stop or server logoff) removes the tab like exit 0.
  ```

- [ ] **Step 1: Write the failing tests**
  ```swift
  @Test func errorNamesMapToPlainReasons()   // LOGON_FAILURE → "logon failed", CONNECT_ACCESS_DENIED → "access denied", CONNECT_TRANSPORT_FAILED and CONNECT_FAILED → "the connection timed out", TLS_CONNECT_FAILED → "the certificate was rejected", CONNECT_CANCELLED → "cancelled", DNS_NAME_NOT_FOUND → "the server refused the connection", unknown "FREERDP_ERROR_FOO" → "FREERDP_ERROR_FOO", nil → "the server closed the session"
  // ConnectionServiceTests
  @Test func rdpConnectionFetchesPasswordThenOpensATab()   // events: ["password login", "tab win (remoteDesktop)"]; executor untouched; the TabRequest carries the config's host and the fetched password
  @Test func rdpWithoutCredentialOpensATabWithEmptyPassword()  // no credential → tab opens, password "" (the sheet asks later)
  @Test func rdpProviderFailureOpensNoTab()                // provider throws → ["notify …"], no tab
  // TerminalSessionsTests
  @Test func disconnectedWithReasonKeepsTheTab()           // host reports .disconnected("logon failed") → state .disconnected, liveCount excludes it
  @Test func reconnectAsksTheHost()                        // sessions.reconnect(id) → host.reconnect called, state back to .running
  ```
- [ ] **Step 2: Run** the three suites — expected: compile failure.
- [ ] **Step 3: Implement** per Interfaces. `RDPHost` presents `RDPPrompts` as sheets on the main window (`NSHostingController` in `beginSheet`) and answers the completions; the password sheet prefills the username; Cancel → completion(nil) → FreeRDP fails the connect → disconnect "cancelled". `terminate()` = `stop`. `apply(_:)` is a no-op.
- [ ] **Step 4: Run** `swift test` — expected: all pass. `make app`.
- [ ] **Step 5: Commit** `feat(rdp): open Windows desktops in tabs with xpnd's prompts`.

### Task 6: Editor fields and the Remote Desktop settings tab

**Files:**
- Modify: `Sources/xpnd/Main/ConnectionEditorView.swift` (RDP: Domain field after Username; "RDP options" `DisclosureGroup` with Display / Sound & Clipboard / Security / Network / Advanced groups; each control is a `Picker`/`Toggle`/`TextField` over an optional binding whose unset state is labelled "Default (<value from AppSettings.shared.remoteDesktop>)"; the `advanced(library)` SSH section stays SSH-only)
- Create: `Sources/xpnd/Settings/RemoteDesktopSettingsView.swift`
- Modify: `Sources/xpnd/Settings/SettingsWindow.swift` (`SettingsSection.remoteDesktop`, title "Remote Desktop", symbol `"pc"`, between terminal and passwordManager)
- Create: `Sources/xpnd/RemoteDesktop/RDPOptionLabels.swift` (pure: `label(for: Display)` → "Resize to fit" / "1920 × 1080" / "Custom 1234 × 567"; `label(for: Audio)` → "Play here" / "Leave on remote" / "Off"; `label(for: Performance)`; `presets: [Display]` = fit, 1280×720, 1920×1080, 2560×1440)
- Test: `Tests/xpndTests/RDPOptionLabelsTests.swift`

- [ ] **Step 1: Write the failing test** `@Test func labels()` asserting the strings above and that `presets.count == 4`.
- [ ] **Step 2: Run** `swift test --filter RDPOptionLabelsTests` — expected: compile failure.
- [ ] **Step 3: Implement** labels, the editor section and the settings tab (same `Form`/`.formStyle(.grouped)` style as `TerminalSettingsView`).
- [ ] **Step 4: Run** `swift test`; `make run` and by hand: create an RDP connection, see Domain and RDP options; every option shows "Default (…)" until changed; Settings → Remote Desktop changes the defaults shown.
- [ ] **Step 5: Commit** `feat(settings): RDP options per connection and Remote Desktop defaults`.

### Task 7: Snippets inside an RDP tab type keystrokes

**Files:**
- Modify: `Sources/xpnd/Expansion/KeystrokeSender.swift` (`typesKeystrokes(in:always:remoteDesktopTabFocused:)`), `Sources/xpnd/App/AppDelegate.swift` / `AppDelegate+Connections.swift` (pass `mainWindow?.focusedSessionKind == .remoteDesktop`), `Sources/xpnd/Main/MainWindowController.swift` (`focusedSessionKind: TerminalSession.Kind?`)
- Test: `Tests/xpndTests/KeystrokeSenderTests.swift`

- [ ] **Step 1: Write the failing test** `@Test func rdpTabTypesKeystrokes()`: `typesKeystrokes(in: "com.jessestilwell.xpnd", always: false, remoteDesktopTabFocused: true)` is true; with `false` it is false.
- [ ] **Step 2: Run** `swift test --filter KeystrokeSenderTests` — expected: compile failure.
- [ ] **Step 3: Implement**; the sender reads the kind through a closure the delegate injects (`AppDelegate` already builds `CGEventKeystrokeSender`; add `focusedSessionKind: @MainActor () -> TerminalSession.Kind?` to its init with a default `{ nil }`).
- [ ] **Step 4: Run** `swift test`; by hand: a snippet keyword typed in the RDP tab is typed into Windows; `;prod` opens a tab.
- [ ] **Step 5: Commit** `feat(expansion): type snippets into a Windows desktop tab`.

### Task 8: Docs, changelog, findings, licences

**Files:**
- Modify: `docs/DEVELOPMENT.md` (Build section: CMake prerequisite, `make freerdp`, how long it takes, the pin-bump procedure; How it works: the RDP component bullet), `README.md` (Connections: RDP; Building: CMake + `make freerdp`), `CHANGELOG.md` (Added: RDP connections in tabs; Remote Desktop settings), `CLAUDE.md` (Rules: bump the FreeRDP pin on security releases; the RDP password exception; Platform findings verified in Tasks 1, 4, 5)
- Verify: `make app` output has `FreeRDP License.txt` and `OpenSSL License.txt` in `Contents/Resources/`

- [ ] **Step 1: Write** the edits.
- [ ] **Step 2: Run** `make app`; `ls build/xpnd.app/Contents/Resources/*License*` shows both files; `swift test` green.
- [ ] **Step 3: Commit** `docs: bundled RDP`.
