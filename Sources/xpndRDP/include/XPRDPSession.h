#import <AppKit/AppKit.h>

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

/// Every call arrives on the main thread. While a certificate or password question is open,
/// FreeRDP's thread waits for its completion; `stop` answers it with reject / nil.
NS_SWIFT_UI_ACTOR
@protocol XPRDPSessionDelegate <NSObject>
- (void)session:(XPRDPSession *)s decideCertificate:(XPRDPCertificate *)c completion:(void (^)(BOOL trust))completion
    NS_SWIFT_NAME(session(_:decideCertificate:completion:));
- (void)session:(XPRDPSession *)s requestPasswordForUser:(NSString *)user host:(NSString *)host
     completion:(void (^)(NSString *_Nullable password))completion;
/// Once per `start`, never after `stop`. nil is a clean end (no error, or the user logged off or
/// disconnected from Windows); otherwise FreeRDP's own error name, e.g. "ERRCONNECT_LOGON_FAILURE",
/// "ERRCONNECT_CONNECT_CANCELLED", "ERRINFO_IDLE_TIMEOUT".
- (void)session:(XPRDPSession *)s didDisconnectWithErrorName:(NSString *_Nullable)errorName;
- (void)sessionDidConnect:(XPRDPSession *)s;
@end

/// One FreeRDP connection shown in `view`. Use it from the main thread only.
NS_SWIFT_UI_ACTOR
@interface XPRDPSession : NSObject
/// `settings` are `[name, value]` pairs applied with `freerdp_settings_set_value_for_name`.
/// The passwords are copied into memory this session zeroes on `stop` and when it is freed.
- (instancetype)initWithSettings:(NSArray<NSArray<NSString *> *> *)settings
                        password:(NSString *)password
                 gatewayPassword:(NSString *_Nullable)gatewayPassword
                        delegate:(id<XPRDPSessionDelegate>)delegate NS_DESIGNATED_INITIALIZER;
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
/// Zeroes and drops the login password (not the gateway's), so the next `start` / `reconnect` asks the
/// delegate for one. Call it while disconnected.
- (void)forgetPassword;

/// Test hooks: a setting by its `FreeRDP_<Name>`; nil / NO for an unknown name, another type, or no context.
- (nullable NSString *)stringSettingNamed:(NSString *)name;
- (BOOL)boolSettingNamed:(NSString *)name;
/// Test hooks: what FreeRDP's LogonErrorInfo callback records (`data`, then `type`, in its order), and
/// the name a disconnect with FreeRDP's last error `code` would report now.
- (void)noteLogonErrorData:(uint32_t)data type:(uint32_t)type;
- (nullable NSString *)disconnectErrorNameForCode:(uint32_t)code;
@end

NS_ASSUME_NONNULL_END
