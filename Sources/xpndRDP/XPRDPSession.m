#import "XPRDPView.h"  // FreeRDP's headers first; see XPRDPView.h

#include <os/log.h>
#include <stdatomic.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/crypto/certificate.h>
#include <freerdp/crypto/certificate_data.h>
#include <freerdp/crypto/certificate_store.h>

#import "XPRDPSession.h"

#pragma mark Secrets

/// NUL-terminated UTF-8 in a buffer this code owns, so it can be zeroed (an NSString can't be).
static NSMutableData *XPSecret(NSString *string) {
    const NSUInteger size = [string lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    [string getCString:data.mutableBytes maxLength:size encoding:NSUTF8StringEncoding];
    return data;
}

static void XPZeroBytes(void *bytes, size_t length) {
    if (bytes && length)
        (void)memset_s(bytes, length, 0, length);
}

static void XPZeroSecret(NSMutableData *_Nullable data) {
    XPZeroBytes(data.mutableBytes, data.length);
}

/// Zeroes FreeRDP's copy of a password before the settings free it.
static void XPZeroSetting(rdpSettings *settings, FreeRDP_Settings_Keys_String key) {
    char *value = freerdp_settings_get_string_writable(settings, key);
    if (value)
        XPZeroBytes(value, strlen(value));
}

/// Zeroes and frees a string FreeRDP handed to AuthenticateEx, then puts a copy of `value` there.
static BOOL XPReplaceString(char **slot, const char *value) {
    if (*slot) {
        XPZeroBytes(*slot, strlen(*slot));
        free(*slot);
    }
    *slot = strdup(value);
    return *slot != NULL;
}

static NSString *XPString(const char *_Nullable value) {
    NSString *string = value ? [NSString stringWithUTF8String:value] : nil;
    return string ?: @"";
}

static BOOL XPIsEmpty(const char *_Nullable value) {
    return !value || !*value;
}

#pragma mark - XPRDPCertificate

@implementation XPRDPCertificate

- (instancetype)initWithHost:(NSString *)host port:(NSInteger)port subject:(NSString *)subject issuer:(NSString *)issuer
           fingerprintSHA256:(NSString *)fingerprint kind:(XPRDPCertificateKind)kind {
    if ((self = [super init])) {
        _host = [host copy];
        _port = port;
        _subject = [subject copy];
        _issuer = [issuer copy];
        _fingerprintSHA256 = [fingerprint copy];
        _kind = kind;
    }
    return self;
}

@end

#pragma mark - XPRDPConnectionInfo

@interface XPRDPConnectionInfo ()
@property NSInteger desktopWidth;
@property NSInteger desktopHeight;
@property (copy) NSString *codec;
@property (copy, nullable) NSNumber *latencyMs;
@property (copy, nullable) NSDate *connectedSince;
@property (copy) NSString *certificateSubject;
@property (copy) NSString *certificateFingerprint;
@property (copy, nullable) NSString *gatewayHost;
@end

@implementation XPRDPConnectionInfo
@end

#pragma mark - XPRDPSession

NSString *const XPRDPErrorCertificateRejected = @"XPRDP_CERTIFICATE_REJECTED";

/// MRDPView's desktop resize (a static function there), captured in PreConnect; the same for every session.
static _Atomic(pDesktopResize) XPMacDesktopResize;
/// MRDPView's channel handlers (static there too), taken out of the pubsub in PreConnect so that its
/// mac_cliprdr_init never claims the clipboard channel; XPChannelConnected passes them the other channels.
/// NULL while they couldn't be found, and so are still subscribed (see XPPreConnect).
static _Atomic(pChannelConnectedEventHandler) XPMacChannelConnected;
static _Atomic(pChannelDisconnectedEventHandler) XPMacChannelDisconnected;
/// GDI's surface command (static there too), captured when the graphics pipeline connects.
static _Atomic(pcRdpgfxSurfaceCommand) XPGdiSurfaceCommand;

static DWORD XPVerifyCertificate(freerdp *, const char *, UINT16, const char *, const char *, const char *, const char *, DWORD);
static DWORD XPVerifyChangedCertificate(freerdp *, const char *, UINT16, const char *, const char *, const char *,
                                        const char *, const char *, const char *, const char *, DWORD);
static BOOL XPAuthenticate(freerdp *, char **, char **, char **, rdp_auth_reason);
static int XPLogonErrorInfo(freerdp *, UINT32, UINT32);
static BOOL XPPreConnect(freerdp *);
static BOOL XPPostConnect(freerdp *);
static void XPPostDisconnect(freerdp *);

@interface XPRDPSession ()
- (void)deliver:(void (^)(id<XPRDPSessionDelegate> delegate))call;
- (nullable id)waitForAnswer:(void (^)(id<XPRDPSessionDelegate> delegate, void (^answer)(id _Nullable value)))ask;
- (void)rememberLogin:(NSArray<NSString *> *)login secret:(NSMutableData *)secret gateway:(BOOL)gateway;
- (void)setDisp:(nullable DispClientContext *)disp;
- (void)didConnect;
- (void)didDisconnectWithCode:(UINT32)code;
- (BOOL)sendLayoutSize:(NSSize)size inViewPoints:(BOOL)points;
@end

@implementation XPRDPSession {
    NSArray<NSArray<NSString *> *> *_settings;
    NSMutableData *_password;
    NSMutableData *_Nullable _gatewayPassword;
    NSString *_Nullable _driveName, *_Nullable _drivePath;
    NSArray<NSString *> *_Nullable _login, *_Nullable _gatewayLogin;  // [user, domain] typed in the sheet
    __weak id<XPRDPSessionDelegate> _delegate;
    XPRDPView *_view;
    rdpContext *_context;  // main thread; FreeRDP's threads reach it through `instance`
    BOOL _started;
    BOOL _followsView;  // main thread: the desktop tracks the view's size
    XPRDPKeyPlayer *_keys;

    // Shared with FreeRDP's threads, under _lock.
    NSLock *_lock;
    BOOL _stopped;            // no delegate calls, no waiting
    NSUInteger _generation;   // bumped by start: calls queued for an earlier connection are dropped
    BOOL _reported;           // didDisconnect sent for this start
    BOOL _connected;
    BOOL _logonFailed;
    BOOL _certificateRejected;
    NSDate *_Nullable _connectedSince;
    DispClientContext *_disp;
    dispatch_semaphore_t _wait;
    id _answer;
    _Atomic(int32_t) _gfxCodec;  // RDPGFX_CODECID_*, -1 for none yet; every frame writes it, so no lock
}

static XPRDPSession *_Nullable XPSessionFor(rdpContext *context) {
    XPRDPView *view = context ? (__bridge XPRDPView *)((mfContext *)context)->view : nil;
    return view.session;
}

- (instancetype)initWithSettings:(NSArray<NSArray<NSString *> *> *)settings password:(NSString *)password
                 gatewayPassword:(NSString *)gatewayPassword delegate:(id<XPRDPSessionDelegate>)delegate {
    return [self initWithSettings:settings password:password gatewayPassword:gatewayPassword driveName:nil drivePath:nil delegate:delegate];
}

- (instancetype)initWithSettings:(NSArray<NSArray<NSString *> *> *)settings password:(NSString *)password
                 gatewayPassword:(NSString *)gatewayPassword driveName:(NSString *)driveName drivePath:(NSString *)drivePath
                        delegate:(id<XPRDPSessionDelegate>)delegate {
    if ((self = [super init])) {
        _settings = [settings copy];
        _password = XPSecret(password);
        _gatewayPassword = gatewayPassword ? XPSecret(gatewayPassword) : nil;
        _driveName = [driveName copy];
        _drivePath = [drivePath copy];
        _delegate = delegate;
        _lock = [NSLock new];
        _view = [[XPRDPView alloc] initWithFrame:NSMakeRect(0, 0, 640, 480)];
        _view.session = self;
        atomic_init(&_gfxCodec, -1);
        XPRDPView *view = _view;
        __weak XPRDPSession *weakSelf = self;
        _keys = [[XPRDPKeyPlayer alloc] initWithScancode:^(uint16_t scancode, BOOL down) {
            [view sendScancode:scancode down:down];
        } text:^(NSString *text) {
            [view sendText:text];
        } canSend:^BOOL {
            return weakSelf.live;
        }];
    }
    return self;
}

- (void)dealloc {
    if (NSThread.isMainThread) {
        [self stop];
    } else if (_context) {
        // Only FreeRDP's thread can drop the last reference here (a callback outlived the owner, who
        // never called stop). It can't join itself: abort, and leave the context and the view (which
        // the thread still uses, unretained) to the exiting thread.
        (void)freerdp_abort_connect_context(_context);
        (void)CFBridgingRetain(_view);
        XPZeroSetting(_context->settings, FreeRDP_Password);
        XPZeroSetting(_context->settings, FreeRDP_GatewayPassword);
        XPZeroSecret(_password);
        XPZeroSecret(_gatewayPassword);
    }
}

- (NSView *)view {
    return _view;
}

- (BOOL)commandAsWindowsKey {
    return _view.commandAsWindowsKey;
}

- (void)setCommandAsWindowsKey:(BOOL)value {
    _view.commandAsWindowsKey = value;
}

#pragma mark Lifecycle

static BOOL XPSetSecret(rdpSettings *settings, FreeRDP_Settings_Keys_String key, NSMutableData *_Nullable secret) {
    // An unset password makes FreeRDP call AuthenticateEx; an empty one would be sent as is.
    if (!secret || XPIsEmpty(secret.bytes))
        return YES;
    return freerdp_settings_set_string(settings, key, secret.bytes);
}

/// What was typed in the sheet, over the settings' username and domain.
static BOOL XPSetLogin(rdpSettings *settings, BOOL gateway, NSArray<NSString *> *_Nullable login) {
    if (!login)
        return YES;
    return freerdp_settings_set_string(settings, gateway ? FreeRDP_GatewayUsername : FreeRDP_Username, login[0].UTF8String) &&
           freerdp_settings_set_string(settings, gateway ? FreeRDP_GatewayDomain : FreeRDP_Domain, login[1].UTF8String);
}

/// Adds the one folder a session redirects.
static BOOL XPAddDrive(rdpSettings *settings, NSString *name, NSString *path) {
    // Both log the names and paths the server asks for.
    (void)WLog_SetLogLevel(WLog_Get("com.freerdp.channels.drive.client"), WLOG_OFF);
    (void)WLog_SetLogLevel(WLog_Get("com.winpr.file"), WLOG_OFF);
    // Not freerdp_client_add_device_channel: for a folder that's missing it logs the path and skips the
    // drive, or redirects `./<name>` instead if that exists.
    const char *args[] = {name.UTF8String, path.UTF8String};
    if (strlen(args[1]) >= MAX_PATH)
        return NO;  // drive_register_drive_path would cut it down to some other folder
    RDPDR_DEVICE *device = freerdp_device_new(RDPDR_DTYP_FILESYSTEM, ARRAYSIZE(args), args);
    if (!device)
        return NO;
    if (!freerdp_device_collection_add(settings, device)) {
        freerdp_device_free(device);
        return NO;
    }
    return freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, YES);
}

- (BOOL)prepare {
    if (_context)
        return YES;
    RDP_CLIENT_ENTRY_POINTS entry = {0};
    if (RdpClientEntry(&entry) != 0)
        return NO;
    // The Mac client's GlobalInit installs process-wide handlers for SIGTERM, SIGINT, SIGHUP and more,
    // and ignores SIGPIPE, which every shell xpnd starts would inherit. FreeRDP's sockets set
    // SO_NOSIGPIPE themselves.
    entry.GlobalInit = NULL;
    rdpContext *ctx = freerdp_client_context_new(&entry);
    if (!ctx)
        return NO;
    rdpSettings *settings = ctx->settings;
    BOOL ok = YES;
    for (NSArray<NSString *> *pair in _settings) {
        ok = pair.count == 2 && freerdp_settings_set_value_for_name(settings, pair[0].UTF8String, pair[1].UTF8String);
        if (!ok)
            break;
    }
    if (ok && _driveName && _drivePath)
        ok = XPAddDrive(settings, _driveName, _drivePath);
    ok = ok && XPSetLogin(settings, NO, _login) && XPSetLogin(settings, YES, _gatewayLogin) &&
         XPSetSecret(settings, FreeRDP_Password, _password) && XPSetSecret(settings, FreeRDP_GatewayPassword, _gatewayPassword);
    if (!ok) {
        XPZeroSetting(settings, FreeRDP_Password);
        XPZeroSetting(settings, FreeRDP_GatewayPassword);
        freerdp_client_context_free(ctx);
        return NO;
    }

    freerdp *instance = ctx->instance;
    instance->VerifyCertificateEx = XPVerifyCertificate;
    instance->VerifyChangedCertificateEx = XPVerifyChangedCertificate;
    instance->AuthenticateEx = XPAuthenticate;
    instance->LogonErrorInfo = XPLogonErrorInfo;
    // freerdp_client_context_new moved the Mac client's connect callbacks here and put the common
    // client's wrappers on the instance, which call these.
    rdpClientContext *cctx = (rdpClientContext *)ctx;
    cctx->PreConnect = XPPreConnect;
    cctx->PostConnect = XPPostConnect;
    cctx->PostDisconnect = XPPostDisconnect;
    // mfreerdp_client_start only makes its own view when this is unset.
    mfContext *mfc = (mfContext *)ctx;
    mfc->view = (__bridge void *)_view;
    mfc->view_ownership = NO;
    _followsView = freerdp_settings_get_bool(settings, FreeRDP_DynamicResolutionUpdate);
    _view.letterbox = !_followsView;
    _context = ctx;
    return YES;
}

- (BOOL)start {
    if (_started)
        return YES;
    if (![self prepare])
        return NO;
    [_lock lock];
    _stopped = NO;
    _generation++;
    _reported = NO;
    _connected = NO;
    _logonFailed = NO;
    _certificateRejected = NO;
    [_lock unlock];
    atomic_store(&_gfxCodec, -1);
    [_view prepareForConnection];
    if (freerdp_client_start(_context) != 0) {  // MRDPView's rdpStart: returns -1 when no thread started
        [self tearDown];
        return NO;
    }
    _started = YES;
    return YES;
}

/// Ends the connection and frees the context; keeps the session's own password copies.
- (void)tearDown {
    [_keys cancel];  // first: its key-ups need the connection
    [_lock lock];
    _stopped = YES;
    _connected = NO;
    _connectedSince = nil;
    _disp = NULL;
    if (_wait) {
        dispatch_semaphore_signal(_wait);  // the waiting callback reads a nil answer
        _wait = nil;
    }
    _answer = nil;
    [_lock unlock];
    if (!_context)
        return;
    if (_started) {
        (void)freerdp_abort_connect_context(_context);
        // shortcut: blocks main until a DNS lookup in progress returns (getaddrinfo can't be aborted),
        // upgrade by joining the client thread off main if a slow resolver makes closing a tab hang.
        (void)freerdp_client_stop(_context);  // waits for the client thread
        _started = NO;
    }
    [_view detachContext];  // rdpStart: may have pointed it at the context even when start failed
    XPZeroSetting(_context->settings, FreeRDP_Password);
    XPZeroSetting(_context->settings, FreeRDP_GatewayPassword);
    freerdp_client_context_free(_context);
    _context = NULL;
}

- (void)stop {
    [self tearDown];
    XPZeroSecret(_password);
    XPZeroSecret(_gatewayPassword);
}

- (void)reconnect {
    [self tearDown];
    if (![self start]) {
        id<XPRDPSessionDelegate> delegate = _delegate;
        [delegate session:self didDisconnectWithErrorName:XPString(freerdp_get_last_error_name(FREERDP_ERROR_CONNECT_FAILED))];
    }
}

- (void)forgetPassword {
    [_lock lock];
    XPZeroSecret(_password);
    _password = XPSecret(@"");  // XPSetSecret leaves an empty one unset, so FreeRDP calls AuthenticateEx
    if (_context) {
        XPZeroSetting(_context->settings, FreeRDP_Password);
        (void)freerdp_settings_set_string(_context->settings, FreeRDP_Password, NULL);
    }
    // The gateway's too: a gateway refusal is also ACCESS_DENIED, and with the same credentials FreeRDP
    // copies an accepted gateway password back to the login (utils_sync_credentials). Kept, either would be
    // sent again without a prompt.
    XPZeroSecret(_gatewayPassword);
    _gatewayPassword = nil;
    if (_context) {
        XPZeroSetting(_context->settings, FreeRDP_GatewayPassword);
        (void)freerdp_settings_set_string(_context->settings, FreeRDP_GatewayPassword, NULL);
    }
    [_lock unlock];
}

#pragma mark Notch

- (void)sendKeySequence:(NSArray<XPRDPKeyStep *> *)steps {
    if (self.live)
        [_keys play:steps];
}

- (void)sendLeftClickAtViewPoint:(NSPoint)point {
    if (self.live)
        [_view sendLeftClickAtViewPoint:point];
}

- (void)setClipboardSyncEnabled:(BOOL)enabled {
    [_view setClipboardSyncEnabled:enabled];
}

- (BOOL)clipboardChannelLoaded {
    return _view.clipboard.channelAttached;
}

- (BOOL)offerFilesForPaste:(NSArray<NSURL *> *)urls {
    return self.live && [_view.clipboard offerFileURLs:urls];
}

/// Lock held. A monitor layout of `size` unless the desktop already has it; NO without Display Control.
- (BOOL)sendLayoutSize:(NSSize)size inViewPoints:(BOOL)points {
    // Checked first, and held throughout: FreeRDP swaps context->settings during a redirection, and
    // PostDisconnect clears _disp under the lock before the channel is freed.
    DispClientContext *disp = _connected && !_stopped && _context ? _disp : NULL;
    if (!disp || !disp->SendMonitorLayout)
        return NO;
    rdpSettings *settings = _context->settings;
    // Task 3's mapping: Retina on ⇔ DesktopScaleFactor 200, and then the desktop is in backing pixels.
    const UINT32 desktopScale = freerdp_settings_get_uint32(settings, FreeRDP_DesktopScaleFactor);
    const NSSize pixels = points && desktopScale > 100 ? [_view convertSizeToBacking:size] : size;
    // MS-RDPEDISP 2.2.2.2.1: width even, both within 200–8192.
    const UINT32 width = MIN(MAX((UINT32)MAX(pixels.width, 0) & ~1u, 200u), 8192u);
    const UINT32 height = MIN(MAX((UINT32)MAX(pixels.height, 0), 200u), 8192u);
    if (width == freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth) &&
        height == freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight))
        return YES;
    DISPLAY_CONTROL_MONITOR_LAYOUT layout = {0};
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = width;
    layout.Height = height;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = desktopScale;
    layout.DeviceScaleFactor = freerdp_settings_get_uint32(settings, FreeRDP_DeviceScaleFactor);
    return disp->SendMonitorLayout(disp, 1, &layout) == CHANNEL_RC_OK;
}

// shortcut: a server that takes the request and keeps its size leaves Fit stretching the old desktop over the view,
// upgrade by choosing the letterbox from the size the server reports back if that shows up in practice.
- (BOOL)requestLayoutSize:(NSSize)size follow:(BOOL)follow {
    [_lock lock];
    const BOOL sent = [self sendLayoutSize:size inViewPoints:follow];
    [_lock unlock];
    if (sent) {
        _followsView = follow;
        _view.letterbox = !follow;
    }
    return sent;
}

- (BOOL)requestDesktopFit {
    return [self requestLayoutSize:_view.bounds.size follow:YES];
}

- (BOOL)requestDesktopWidth:(NSInteger)width height:(NSInteger)height {
    return [self requestLayoutSize:NSMakeSize(width, height) follow:NO];
}

static NSString *_Nullable XPCodecName(int32_t codecId) {
    switch (codecId) {
        case RDPGFX_CODECID_UNCOMPRESSED: return @"bitmap";
        case RDPGFX_CODECID_CAVIDEO: return @"RemoteFX";
        case RDPGFX_CODECID_PLANAR: return @"planar";
        case RDPGFX_CODECID_CAPROGRESSIVE:
        case RDPGFX_CODECID_CAPROGRESSIVE_V2: return @"progressive";
        default: return nil;
    }
}

// shortcut: FreeRDP neither asks about nor stores a certificate that verifies against a CA, and keeps the peer's to
// itself, so such a server shows none; upgrade if its API ever hands the transport's certificate out.
/// Known hosts rather than the certificate callback: that runs once per certificate, not per connect, and for a
/// gateway's too. Whatever was accepted is there by now, as XPAskAboutCertificate answers "accept and store".
static void XPReadCertificate(rdpSettings *settings, XPRDPConnectionInfo *info) {
    const char *host = freerdp_settings_get_string(settings, FreeRDP_ServerHostname);
    rdpCertificateStore *store = host ? freerdp_certificate_store_new(settings) : NULL;
    if (!store)
        return;
    const UINT32 port = freerdp_settings_get_uint32(settings, FreeRDP_ServerPort);
    rdpCertificateData *data = freerdp_certificate_store_load_data(store, host, (UINT16)port);
    if (data) {
        info.certificateSubject = XPString(freerdp_certificate_data_get_subject(data));
        info.certificateFingerprint = XPString(freerdp_certificate_data_get_fingerprint(data));
    }
    freerdp_certificate_data_free(data);
    freerdp_certificate_store_free(store);
}

- (XPRDPConnectionInfo *)connectionInfo {
    XPRDPConnectionInfo *info = [XPRDPConnectionInfo new];
    info.codec = XPCodecName(atomic_load(&_gfxCodec)) ?: @"—";
    info.certificateSubject = @"";
    info.certificateFingerprint = @"";
    [_lock lock];  // as sendLayoutSize:, for the settings
    info.connectedSince = _connectedSince;
    if (_context) {
        rdpSettings *settings = _context->settings;
        info.desktopWidth = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
        info.desktopHeight = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
        const UINT32 latency = _context->autodetect ? _context->autodetect->netCharAverageRTT : 0;
        info.latencyMs = latency ? @(latency) : nil;
        if (freerdp_settings_get_bool(settings, FreeRDP_GatewayEnabled))
            info.gatewayHost = XPString(freerdp_settings_get_string(settings, FreeRDP_GatewayHostname));
        XPReadCertificate(settings, info);
    }
    [_lock unlock];
    return info;
}

#pragma mark Test hooks

- (NSUInteger)deviceCount {
    return _context ? freerdp_settings_get_uint32(_context->settings, FreeRDP_DeviceCount) : 0;
}

- (nullable NSString *)drivePathAtIndex:(NSUInteger)index {
    if (index >= self.deviceCount)
        return nil;
    const RDPDR_DRIVE *drive = freerdp_settings_get_pointer_array(_context->settings, FreeRDP_DeviceArray, index);
    return drive && drive->device.Type == RDPDR_DTYP_FILESYSTEM ? XPString(drive->Path) : nil;
}

- (nullable NSString *)stringSettingNamed:(NSString *)name {
    const SSIZE_T key = freerdp_settings_get_key_for_name(name.UTF8String);
    if (!_context || key < 0 || freerdp_settings_get_type_for_key(key) != RDP_SETTINGS_TYPE_STRING)
        return nil;
    const char *value = freerdp_settings_get_string(_context->settings, (FreeRDP_Settings_Keys_String)key);
    return value ? [NSString stringWithUTF8String:value] : nil;
}

- (BOOL)boolSettingNamed:(NSString *)name {
    const SSIZE_T key = freerdp_settings_get_key_for_name(name.UTF8String);
    if (!_context || key < 0 || freerdp_settings_get_type_for_key(key) != RDP_SETTINGS_TYPE_BOOL)
        return NO;
    return freerdp_settings_get_bool(_context->settings, (FreeRDP_Settings_Keys_Bool)key);
}

- (nullable NSString *)disconnectErrorNameForCode:(uint32_t)code {
    [_lock lock];
    const BOOL logonFailed = _logonFailed, certificateRejected = _certificateRejected;
    [_lock unlock];
    if (certificateRejected && code == FREERDP_ERROR_TLS_CONNECT_FAILED)
        return XPRDPErrorCertificateRejected;
    // A server that rejects the password at its own logon screen ends with a generic error.
    if (logonFailed && (code == FREERDP_ERROR_SUCCESS || code == FREERDP_ERROR_CONNECT_FAILED))
        code = FREERDP_ERROR_CONNECT_LOGON_FAILURE;
    // Logging off or disconnecting from Windows ends the session as the user asked, like closing the tab.
    if (code == FREERDP_ERROR_SUCCESS || code == FREERDP_ERROR_LOGOFF_BY_USER || code == FREERDP_ERROR_RPC_INITIATED_DISCONNECT_BY_USER)
        return nil;
    return XPString(freerdp_get_last_error_name(code));
}

#pragma mark Talking to the delegate

/// Any thread: runs `call` on main unless the session stopped or started again in between.
- (void)deliver:(void (^)(id<XPRDPSessionDelegate> delegate))call {
    [_lock lock];
    const NSUInteger generation = _generation;
    [_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_lock lock];
        const BOOL current = !self->_stopped && self->_generation == generation;
        [self->_lock unlock];
        id<XPRDPSessionDelegate> delegate = self->_delegate;
        if (current && delegate)
            call(delegate);
    });
}

/// FreeRDP's thread: asks on main and blocks until answered; nil when stopped meanwhile.
- (nullable id)waitForAnswer:(void (^)(id<XPRDPSessionDelegate> delegate, void (^answer)(id _Nullable value)))ask {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [_lock lock];
    if (_stopped) {
        [_lock unlock];
        return nil;
    }
    _wait = semaphore;
    _answer = nil;
    [_lock unlock];

    __weak XPRDPSession *weakSelf = self;
    void (^answer)(id) = ^(id value) {
        XPRDPSession *s = weakSelf;
        if (!s) return;
        [s->_lock lock];
        if (s->_wait == semaphore) {  // the first answer to this question, and not stopped
            s->_wait = nil;
            s->_answer = value;
            dispatch_semaphore_signal(semaphore);
        }
        [s->_lock unlock];
    };
    [self deliver:^(id<XPRDPSessionDelegate> delegate) {
        ask(delegate, answer);
    }];
    // deliver drops the question if the session stops first; stop then signals.
    (void)dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

    [_lock lock];
    id result = _answer;
    _answer = nil;
    [_lock unlock];
    return result;
}

#pragma mark FreeRDP callbacks (FreeRDP's threads)

static DWORD XPAskAboutCertificate(freerdp *instance, const char *host, UINT16 port, const char *subject,
                                   const char *issuer, const char *fingerprint, DWORD flags, XPRDPCertificateKind kind) {
    XPRDPSession *s = XPSessionFor(instance->context);
    if (!s)
        return 0;
    NSString *sha256 = nil;
    if (flags & VERIFY_CERT_FLAG_FP_IS_PEM) {
        // Only with FreeRDP_CertificateCallbackPreferPEM, which xpnd doesn't set; hash the DER anyway.
        rdpCertificate *certificate = freerdp_certificate_new_from_pem(fingerprint);
        char *hex = certificate ? freerdp_certificate_get_fingerprint_by_hash(certificate, "sha256") : NULL;
        sha256 = XPString(hex);
        free(hex);
        freerdp_certificate_free(certificate);
    } else {
        sha256 = XPString(fingerprint);
    }
    XPRDPCertificate *certificate = [[XPRDPCertificate alloc] initWithHost:XPString(host) port:port subject:XPString(subject)
                                                                    issuer:XPString(issuer) fingerprintSHA256:sha256 kind:kind];
    NSNumber *trust = [s waitForAnswer:^(id<XPRDPSessionDelegate> delegate, void (^answer)(id)) {
        [delegate session:s decideCertificate:certificate completion:^(BOOL value) {
            answer(@(value));
        }];
    }];
    [s noteCertificateTrusted:trust.boolValue];
    // 1 accepts and stores in ConfigPath's known hosts (tls.c), so a later change shows as Changed;
    // 2 would accept for this session only.
    return trust.boolValue ? 1 : 0;
}

static DWORD XPVerifyCertificate(freerdp *instance, const char *host, UINT16 port, const char *commonName,
                                 const char *subject, const char *issuer, const char *fingerprint, DWORD flags) {
    const XPRDPCertificateKind kind = (flags & VERIFY_CERT_FLAG_CHANGED) ? XPRDPCertificateKindChanged : XPRDPCertificateKindUnknown;
    return XPAskAboutCertificate(instance, host, port, subject, issuer, fingerprint, flags, kind);
}

static DWORD XPVerifyChangedCertificate(freerdp *instance, const char *host, UINT16 port, const char *commonName,
                                        const char *subject, const char *issuer, const char *fingerprint,
                                        const char *oldSubject, const char *oldIssuer, const char *oldFingerprint, DWORD flags) {
    return XPAskAboutCertificate(instance, host, port, subject, issuer, fingerprint, flags, XPRDPCertificateKindChanged);
}

/// `username` / `password` / `domain` point at the settings' own strings.
static BOOL XPAuthenticate(freerdp *instance, char **username, char **password, char **domain, rdp_auth_reason reason) {
    XPRDPSession *s = XPSessionFor(instance->context);
    if (!s || !username || !password || !domain)
        return NO;
    BOOL gateway;
    switch (reason) {
        case AUTH_NLA:
        case AUTH_TLS:
        case AUTH_RDP:
            gateway = NO;
            break;
        case GW_AUTH_HTTP:
        case GW_AUTH_RDG:
        case GW_AUTH_RPC:
            gateway = YES;
            break;
        default:
            return NO;  // smart card and FIDO PINs: not supported
    }
    if (!XPIsEmpty(*username) && !XPIsEmpty(*password))
        return YES;
    rdpSettings *settings = instance->context->settings;
    NSString *user = XPString(*username), *domainName = XPString(*domain);
    NSString *host = XPString(freerdp_settings_get_string(settings, gateway ? FreeRDP_GatewayHostname : FreeRDP_ServerHostname));
    NSArray<NSString *> *typed = [s waitForAnswer:^(id<XPRDPSessionDelegate> delegate, void (^answer)(id)) {
        [delegate session:s requestPasswordForUser:user domain:domainName host:host
               completion:^(NSString *typedUser, NSString *typedDomain, NSString *typedPassword) {
                   answer(typedPassword ? @[ typedUser, typedDomain, typedPassword ] : nil);
               }];
    }];
    if (!typed)
        return NO;  // FreeRDP ends the connect as cancelled
    NSArray<NSString *> *login = @[ typed[0], typed[1] ];
    NSMutableData *secret = XPSecret(typed[2]);
    const BOOL ok = XPReplaceString(username, login[0].UTF8String) && XPReplaceString(domain, login[1].UTF8String) &&
                    XPReplaceString(password, secret.bytes);
    [s rememberLogin:login secret:secret gateway:gateway];  // reconnect uses what was typed
    return ok;
}

static int XPLogonErrorInfo(freerdp *instance, UINT32 data, UINT32 type) {
    [XPSessionFor(instance->context) noteLogonErrorData:data type:type];
    return 1;
}

static XPRDPView *XPViewFor(void *context) {
    return (__bridge XPRDPView *)((mfContext *)context)->view;
}

/// FreeRDP keeps no "codec in use", only this per-frame id.
static UINT XPSurfaceCommand(RdpgfxClientContext *gfx, const RDPGFX_SURFACE_COMMAND *command) {
    [XPSessionFor(((rdpGdi *)gfx->custom)->context) noteGfxCodec:(uint16_t)command->codecId];
    return atomic_load(&XPGdiSurfaceCommand)(gfx, command);
}

static void XPChannelConnected(void *context, const ChannelConnectedEventArgs *e) {
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        (void)[XPViewFor(context).clipboard attachChannel:(CliprdrClientContext *)e->pInterface];
        return;
    }
    const pChannelConnectedEventHandler mac = atomic_load(&XPMacChannelConnected);
    if (mac)
        mac(context, e);
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
        [XPSessionFor(context) setDisp:(DispClientContext *)e->pInterface];
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        // gdi_graphics_pipeline_init ran in the handler above (or, with `mac` NULL, before this one).
        RdpgfxClientContext *gfx = (RdpgfxClientContext *)e->pInterface;
        if (gfx->SurfaceCommand && gfx->SurfaceCommand != XPSurfaceCommand) {
            atomic_store(&XPGdiSurfaceCommand, gfx->SurfaceCommand);
            gfx->SurfaceCommand = XPSurfaceCommand;
        }
    }
}

static void XPChannelDisconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        [XPViewFor(context).clipboard detachChannel:(CliprdrClientContext *)e->pInterface];
        return;
    }
    const pChannelDisconnectedEventHandler mac = atomic_load(&XPMacChannelDisconnected);
    if (mac)
        mac(context, e);
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
        [XPSessionFor(context) setDisp:NULL];
}

/// Pre-connect, before any channel runs: nothing else touches the pubsub.
static size_t XPHandlerCount(wPubSub *pubSub, const char *event) {
    const wEventType *type = PubSub_FindEventType(pubSub, event);
    return type ? type->EventHandlerCount : 0;
}

/// The one handler subscribed to `event` since it had `before`; NULL when there isn't exactly one.
static pEventHandler XPHandlerAdded(wPubSub *pubSub, const char *event, size_t before) {
    const wEventType *type = PubSub_FindEventType(pubSub, event);
    return type && type->EventHandlerCount == before + 1 ? type->EventHandlers[before] : NULL;
}

/// MRDPView's EndPaint waits on the main queue (dispatch_sync) for every frame, which deadlocks a
/// main thread joining the client thread in stop. This one only queues the redraw.
static BOOL XPEndPaint(rdpContext *context) {
    rdpGdi *gdi = context ? context->gdi : NULL;
    if (!gdi || !gdi->primary || !gdi->primary->hdc)
        return NO;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (!hwnd || !hwnd->invalid || hwnd->invalid->null)
        return YES;
    const NSRect rect = NSMakeRect(hwnd->invalid->x, hwnd->invalid->y, hwnd->invalid->w, hwnd->invalid->h);
    const NSSize desktop = NSMakeSize(gdi->width, gdi->height);
    hwnd->ninvalid = 0;
    XPRDPView *view = (__bridge XPRDPView *)((mfContext *)context)->view;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view invalidateDesktopRect:rect desktopSize:desktop];
    });
    return YES;
}

static BOOL XPDesktopResize(rdpContext *context) {
    XPRDPView *view = (__bridge XPRDPView *)((mfContext *)context)->view;
    const pDesktopResize resize = atomic_load(&XPMacDesktopResize);
    [view lockDrawing];  // it swaps the image drawRect: reads
    const BOOL ok = resize ? resize(context) : YES;
    [view unlockDrawing];
    return ok;
}

static BOOL XPPreConnect(freerdp *instance) {
    rdpContext *context = instance->context;
    wPubSub *pubSub = context->pubSub;
    const size_t connected = XPHandlerCount(pubSub, "ChannelConnected");
    const size_t disconnected = XPHandlerCount(pubSub, "ChannelDisconnected");
    if (!mac_pre_connect(instance))
        return NO;
    // Both or neither, so mac_cliprdr_init and mac_cliprdr_uninit stay paired. Should a FreeRDP update
    // change what mac_pre_connect subscribes, its handlers stay and run first: mac_cliprdr_init still runs,
    // and XPRDPClipboard's attach, after it, replaces every callback it set.
    pEventHandler mac = XPHandlerAdded(pubSub, "ChannelConnected", connected);
    pEventHandler macDisconnected = XPHandlerAdded(pubSub, "ChannelDisconnected", disconnected);
    if (mac && macDisconnected) {
        (void)PubSub_Unsubscribe(pubSub, "ChannelConnected", mac);
        (void)PubSub_Unsubscribe(pubSub, "ChannelDisconnected", macDisconnected);
    } else {
        os_log_error(os_log_create("com.jessestilwell.xpnd", "rdp"), "MRDPView's channel handlers not found; FreeRDP's Mac clipboard runs first");
        mac = macDisconnected = NULL;
    }
    atomic_store(&XPMacChannelConnected, (pChannelConnectedEventHandler)mac);
    atomic_store(&XPMacChannelDisconnected, (pChannelDisconnectedEventHandler)macDisconnected);
    rdpUpdate *update = context->update;
    atomic_store(&XPMacDesktopResize, update->DesktopResize);
    update->DesktopResize = XPDesktopResize;
    update->EndPaint = XPEndPaint;
    (void)PubSub_SubscribeChannelConnected(context->pubSub, XPChannelConnected);
    (void)PubSub_SubscribeChannelDisconnected(context->pubSub, XPChannelDisconnected);
    return YES;
}

static BOOL XPPostConnect(freerdp *instance) {
    XPRDPView *view = (__bridge XPRDPView *)((mfContext *)instance->context)->view;
    [view lockDrawing];  // gdi_init and the new image
    const BOOL ok = mac_post_connect(instance);
    [view unlockDrawing];
    if (ok)
        [view.session didConnect];
    return ok;
}

static void XPPostDisconnect(freerdp *instance) {
    rdpContext *context = instance->context;
    XPRDPView *view = (__bridge XPRDPView *)((mfContext *)context)->view;
    [view dropDesktopImage];  // before mac_post_disconnect's gdi_free
    (void)PubSub_UnsubscribeChannelConnected(context->pubSub, XPChannelConnected);
    (void)PubSub_UnsubscribeChannelDisconnected(context->pubSub, XPChannelDisconnected);
    mac_post_disconnect(instance);
    [view.session didDisconnectWithCode:freerdp_get_last_error(context)];
}

#pragma mark State from FreeRDP's threads

/// Main reads these only before start and after stop's join, never while this thread runs.
- (void)rememberLogin:(NSArray<NSString *> *)login secret:(NSMutableData *)secret gateway:(BOOL)gateway {
    XPZeroSecret(gateway ? _gatewayPassword : _password);
    if (gateway) {
        _gatewayLogin = login;
        _gatewayPassword = secret;
    } else {
        _login = login;
        _password = secret;
    }
}

/// FreeRDP's `data` is the ErrorNotificationData (LOGON_FAILED_*) and `type` the ErrorNotificationType
/// (LOGON_MSG_* or an NTSTATUS); for LOGON_MSG_* types `data` is a session id, so 0 isn't BAD_PASSWORD.
- (void)noteLogonErrorData:(uint32_t)data type:(uint32_t)type {
    [_lock lock];
    if (type == LOGON_MSG_SESSION_CONTINUE)
        _logonFailed = NO;  // the user got past Windows' logon screen after all
    else if (type < LOGON_MSG_SESSION_BUSY_OPTIONS &&
             (data == LOGON_FAILED_BAD_PASSWORD || data == LOGON_FAILED_UPDATE_PASSWORD || data == LOGON_FAILED_OTHER))
        _logonFailed = YES;
    [_lock unlock];
}

- (void)noteCertificateTrusted:(BOOL)trusted {
    [_lock lock];
    _certificateRejected = !trusted;
    [_lock unlock];
}

/// ClearCodec and alpha only touch up frames (text, edges), so they don't count as the codec in use.
- (void)noteGfxCodec:(uint16_t)codecId {
    if (XPCodecName(codecId))
        atomic_store(&_gfxCodec, codecId);
}

- (void)setDisp:(DispClientContext *)disp {
    [_lock lock];
    _disp = disp;
    [_lock unlock];
    if (disp)
        dispatch_async(dispatch_get_main_queue(), ^{
            [self viewSizeSettled:self->_view.bounds.size];  // the tab may have changed size while connecting
        });
}

- (void)didConnect {
    [_lock lock];
    _connected = YES;
    _connectedSince = [NSDate date];
    _logonFailed = NO;  // with NLA a failure comes before this; with TLS the server reports it afterwards
    [_lock unlock];
    [self deliver:^(id<XPRDPSessionDelegate> delegate) {
        [delegate sessionDidConnect:self];
    }];
}

- (void)didDisconnectWithCode:(UINT32)code {
    [_lock lock];
    const BOOL first = !_reported;
    _reported = YES;
    _connected = NO;
    _connectedSince = nil;
    _disp = NULL;
    [_lock unlock];
    if (!first)
        return;
    NSString *name = [self disconnectErrorNameForCode:code];
    [self deliver:^(id<XPRDPSessionDelegate> delegate) {
        [delegate session:self didDisconnectWithErrorName:name];
    }];
}

@end

#pragma mark - Display control

@implementation XPRDPSession (XPRDPView)

- (void)viewSizeSettled:(CGSize)size {
    [_lock lock];
    if (_followsView)
        (void)[self sendLayoutSize:size inViewPoints:YES];
    [_lock unlock];
}

- (BOOL)live {
    [_lock lock];
    const BOOL live = _connected && !_stopped && _context;
    [_lock unlock];
    return live;
}

@end
