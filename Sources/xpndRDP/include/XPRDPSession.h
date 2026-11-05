#import <AppKit/AppKit.h>

#import "XPRDPKeyPlayer.h"

NS_ASSUME_NONNULL_BEGIN

@class XPRDPSession;

typedef NS_ENUM(NSInteger, XPRDPCertificateKind) {
    XPRDPCertificateKindUnknown,  ///< not seen before
    XPRDPCertificateKindChanged,  ///< differs from the one stored for this host
};

/// The server's (or gateway's) certificate FreeRDP asks about.
@interface XPRDPCertificate : NSObject
@property (readonly, copy) NSString *host;
@property (readonly) NSInteger port;
@property (readonly, copy) NSString *subject;
@property (readonly, copy) NSString *issuer;
/// Colon-separated hex SHA-256 of the certificate.
@property (readonly, copy) NSString *fingerprintSHA256;
@property (readonly) XPRDPCertificateKind kind;
- (instancetype)initWithHost:(NSString *)host port:(NSInteger)port subject:(NSString *)subject issuer:(NSString *)issuer
           fingerprintSHA256:(NSString *)fingerprint kind:(XPRDPCertificateKind)kind NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// What the session knows about its connection, as of the moment it was asked.
@interface XPRDPConnectionInfo : NSObject
/// 0 with no context.
@property (readonly) NSInteger desktopWidth;
@property (readonly) NSInteger desktopHeight;
/// "RemoteFX", "progressive", "planar", "bitmap", or "—" before the first graphics-pipeline frame.
@property (readonly, copy) NSString *codec;
/// The server's measured round trip; nil if it reported none.
@property (readonly, copy, nullable) NSNumber *latencyMs;
@property (readonly, copy, nullable) NSDate *connectedSince;
/// From FreeRDP's known hosts; "" for a certificate that isn't there (see `connectionInfo`).
@property (readonly, copy) NSString *certificateSubject;
/// Colon-separated hex SHA-256.
@property (readonly, copy) NSString *certificateFingerprint;
@property (readonly, copy, nullable) NSString *gatewayHost;
@end

/// Every call arrives on the main thread. While a certificate or password question is open,
/// FreeRDP's thread waits for its completion; `stop` answers it with reject / nil.
NS_SWIFT_UI_ACTOR
@protocol XPRDPSessionDelegate <NSObject>
- (void)session:(XPRDPSession *)s decideCertificate:(XPRDPCertificate *)c completion:(void (^)(BOOL trust))completion
    NS_SWIFT_NAME(session(_:decideCertificate:completion:));
/// FreeRDP has no username or password for `host` (the server's or the gateway's). `user` and `domain`
/// are what it has ("" for none), to prefill; a nil password cancels the connect.
- (void)session:(XPRDPSession *)s requestPasswordForUser:(NSString *)user domain:(NSString *)domain host:(NSString *)host
     completion:(void (^)(NSString *user, NSString *domain, NSString *_Nullable password))completion;
/// Once per `start`, never after `stop`. nil is a clean end (no error, or the user logged off or
/// disconnected from Windows); otherwise FreeRDP's own error name, e.g. "ERRCONNECT_LOGON_FAILURE",
/// "ERRCONNECT_CONNECT_CANCELLED", "ERRINFO_IDLE_TIMEOUT".
- (void)session:(XPRDPSession *)s didDisconnectWithErrorName:(NSString *_Nullable)errorName;
- (void)sessionDidConnect:(XPRDPSession *)s;
@end

/// The disconnect name when the user declined the certificate (FreeRDP reports a TLS failure).
extern NSString *const XPRDPErrorCertificateRejected;

/// One FreeRDP connection shown in `view`. Use it from the main thread only.
NS_SWIFT_UI_ACTOR
@interface XPRDPSession : NSObject
/// `settings` are `[name, value]` pairs applied with `freerdp_settings_set_value_for_name`.
/// The passwords are copied into memory this session zeroes on `stop` and when it is freed.
/// With `driveName` and `drivePath`, that one folder is redirected into the session as a drive.
- (instancetype)initWithSettings:(NSArray<NSArray<NSString *> *> *)settings
                        password:(NSString *)password
                 gatewayPassword:(NSString *_Nullable)gatewayPassword
                       driveName:(NSString *_Nullable)driveName
                       drivePath:(NSString *_Nullable)drivePath
                        delegate:(id<XPRDPSessionDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithSettings:(NSArray<NSArray<NSString *> *> *)settings
                        password:(NSString *)password
                 gatewayPassword:(NSString *_Nullable)gatewayPassword
                        delegate:(id<XPRDPSessionDelegate>)delegate;
- (instancetype)init NS_UNAVAILABLE;

/// The desktop; lives as long as the session, across reconnects.
@property (readonly) NSView *view;
/// YES (default): ⌘C/⌘V/⌘X/⌘Z/⌘A reach Windows as Ctrl+key and ⌘ is the Windows key otherwise.
/// NO: ⌘ is Ctrl for every key.
@property BOOL commandAsWindowsKey;

/// Creates the context and applies the settings and passwords without starting a thread; idempotent.
/// NO when the context can't be created or a setting is unknown or unparsable.
- (BOOL)prepare;
/// `prepare`, then the client thread. NO if either fails.
- (BOOL)start;
/// Aborts and joins the client thread, zeroes the passwords, frees the context. No delegate call
/// arrives after it returns. Blocks while FreeRDP finishes a DNS lookup in progress.
- (void)stop;
/// Tears down the connection and starts again with the same settings and the latest password.
- (void)reconnect;
/// `reconnect` with `settings` (as at init) in place of the old ones; the passwords and drive stay.
- (void)reconnectWithSettings:(NSArray<NSArray<NSString *> *> *)settings;
/// Zeroes and drops the login and gateway passwords, so the next `start` / `reconnect` asks the delegate
/// for them. Call it while disconnected. With a client thread, FreeRDP's copy goes at the following
/// `reconnect` or `stop`.
- (void)forgetPassword;

/// Scancodes, text and pauses, in order, behind any sequence still pausing. Nothing unless connected; what is
/// left when the session stops is dropped, its held keys released.
- (void)sendKeySequence:(NSArray<XPRDPKeyStep *> *)steps;
/// One left click, down then up, at `point` in `view`'s coordinates. Nothing unless connected.
- (void)sendLeftClickAtViewPoint:(NSPoint)point;

/// xpnd used the ⌘ being held (a shortcut, a ⌘-click on its own controls), so releasing it doesn't tap the Windows key.
- (void)noteCommandUsed;

/// NO stops the pasteboard poll, sends an empty format list and ignores the server's lists; it lasts across
/// reconnects, until YES.
- (void)setClipboardSyncEnabled:(BOOL)enabled;
/// YES while the cliprdr channel is connected.
@property (readonly) BOOL clipboardChannelLoaded;
/// Offers `urls` (file URLs only) on the remote clipboard, and nothing else. `completion` runs once, on the main
/// queue: YES when the server has accepted the offer, so a paste gets these files and not what Windows held.
/// NO on a refusal, after 2 seconds, when the session ends or a newer offer replaces this one, and at once unless
/// connected with the channel in sync and clipboard sync on.
- (void)offerFilesForPaste:(NSArray<NSURL *> *)urls completion:(void (^)(BOOL accepted))completion;
/// Set to take files dropped on `view`, with where they landed in its coordinates. Without it, or unless
/// connected, `view` refuses them.
@property (copy, nullable) void (^dropHandler)(NSArray<NSURL *> *urls, NSPoint viewPoint);

/// Asks the server for the view's size, and to follow it from now on. NO without Display Control, for this
/// connection only: `reconnect` goes back to the settings.
- (BOOL)requestDesktopFit;
/// Asks the server for a size in desktop pixels, letterboxed from now on. As `requestDesktopFit`.
- (BOOL)requestDesktopWidth:(NSInteger)width height:(NSInteger)height;

@property (readonly) XPRDPConnectionInfo *connectionInfo;

/// Test hook: the redirected devices in the context; 0 without one.
- (NSUInteger)deviceCount;
/// Test hook: the folder behind a redirected drive.
- (nullable NSString *)drivePathAtIndex:(NSUInteger)index;
/// What the graphics pipeline's frame callback records, by RDPGFX_CODECID_*.
- (void)noteGfxCodec:(uint16_t)codecId;
/// Test hooks: a setting by its `FreeRDP_<Name>`; nil / NO for an unknown name, another type, or no context.
- (nullable NSString *)stringSettingNamed:(NSString *)name;
- (BOOL)boolSettingNamed:(NSString *)name;
/// Test hooks: what FreeRDP's LogonErrorInfo callback records (`data`, then `type`, in its order), and
/// the name a disconnect with FreeRDP's last error `code` would report now.
- (void)noteLogonErrorData:(uint32_t)data type:(uint32_t)type;
/// Test hook: what the certificate sheet answered, as the certificate callback records it.
- (void)noteCertificateTrusted:(BOOL)trusted;
- (nullable NSString *)disconnectErrorNameForCode:(uint32_t)code;
@end

NS_ASSUME_NONNULL_END
