// FreeRDP and winpr before Cocoa: see XPRDPVersion.m.
#include <winpr/clipboard.h>
#include <winpr/wlog.h>
#include <freerdp/client/client_cliprdr_file.h>
#include <freerdp/utils/cliprdr_utils.h>

#import "XPRDPClipboard+Channel.h"

#import <AppKit/AppKit.h>

#import "XPRDPClipboardFilter.h"

static const char XPMimeText[] = "text/plain;charset=utf-8";
static const char XPMimeURIList[] = "text/uri-list";
static const char XPFileGroupDescriptorW[] = "FileGroupDescriptorW";

static UINT XPMonitorReady(CliprdrClientContext *, const CLIPRDR_MONITOR_READY *);
static UINT XPServerCapabilities(CliprdrClientContext *, const CLIPRDR_CAPABILITIES *);
static UINT XPServerFormatList(CliprdrClientContext *, const CLIPRDR_FORMAT_LIST *);
static UINT XPServerFormatListResponse(CliprdrClientContext *, const CLIPRDR_FORMAT_LIST_RESPONSE *);
static UINT XPServerFormatDataRequest(CliprdrClientContext *, const CLIPRDR_FORMAT_DATA_REQUEST *);
static UINT XPServerFormatDataResponse(CliprdrClientContext *, const CLIPRDR_FORMAT_DATA_RESPONSE *);

@implementation XPRDPClipboard {
    NSLock *_lock;  // everything below
    wClipboard *_clip;
    wClipboard *_fileClip;  // the channel's thread only, outside the lock: uri list → descriptors
    CliprdrFileContext *_file;
    CliprdrClientContext *_cliprdr;  // while attached
    BOOL _sync;                      // MonitorReady seen: the server takes format lists
    BOOL _enabled;
    UINT32 _requestedFormatId;       // the server text format asked for, or 0
    NSString *_text;                 // the Mac clipboard's offer
    NSData *_uriList;
    NSInteger _writtenChangeCount;  // main thread: the pasteboard change our own write of server text made
}

+ (XPRDPClipboardFormats)formatsToAnnounceForPasteboardTypes:(NSArray<NSString *> *)types {
    if (![XPRDPClipboardFilter shouldOfferPasteboardTypes:types])
        return 0;
    XPRDPClipboardFormats formats = 0;
    if ([types containsObject:NSPasteboardTypeString])
        formats |= XPRDPClipboardFormatsText;
    if ([types containsObject:NSPasteboardTypeFileURL] || [types containsObject:@"NSFilenamesPboardType"])
        formats |= XPRDPClipboardFormatsFiles;
    return formats;
}

+ (nullable NSData *)fileURIListForURLs:(NSArray<NSURL *> *)urls {
    NSMutableString *list = [NSMutableString string];
    for (NSURL *url in urls) {
        // cliprdr_file_apple_get_uri_list's form; a Finder drag carries file reference URLs too.
        NSURL *path = url.isFileURL ? url.filePathURL : nil;
        if (path)
            [list appendFormat:@"%@\r\n", path.absoluteString];
    }
    return list.length ? [list dataUsingEncoding:NSUTF8StringEncoding] : nil;
}

+ (NSArray<NSURL *> *)fileURLsOnPasteboard:(NSPasteboard *)pasteboard {
    return [pasteboard readObjectsForClasses:@[ NSURL.class ] options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}] ?: @[];
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _enabled = YES;
        _writtenChangeCount = -1;
        _clip = ClipboardCreate();
        _fileClip = ClipboardCreate();
        // Both log local file names and paths (a name Windows refuses, a file that can't be opened).
        WLog_SetLogLevel(WLog_Get("com.winpr.clipboard.synthetic.file"), WLOG_OFF);
        WLog_SetLogLevel(WLog_Get("com.freerdp.client.common.cliprdr.file"), WLOG_OFF);
        _file = cliprdr_file_context_new((__bridge void *)self);  // unretained: the view owns self
        // Gates the file capability flags (cliprdr_file_context_current_flags), so it is needed for
        // Mac → Windows too.
        if (_file)
            (void)cliprdr_file_context_set_locally_available(_file, YES);
    }
    return self;
}

- (void)dealloc {
    cliprdr_file_context_free(_file);
    ClipboardDestroy(_clip);
    ClipboardDestroy(_fileClip);
}

static XPRDPClipboard *_Nullable XPClipboardFor(CliprdrClientContext *cliprdr) {
    CliprdrFileContext *file = cliprdr ? (CliprdrFileContext *)cliprdr->custom : NULL;
    return file ? (__bridge XPRDPClipboard *)cliprdr_file_context_get_context(file) : nil;
}

#pragma mark Channel

- (BOOL)attachChannel:(CliprdrClientContext *)cliprdr {
    [_lock lock];
    // Sets cliprdr->custom to the file context, and the lock, unlock and FileContents callbacks.
    const BOOL ok = _clip && _fileClip && _file && cliprdr_file_context_init(_file, cliprdr);
    if (ok) {
        cliprdr->MonitorReady = XPMonitorReady;
        cliprdr->ServerCapabilities = XPServerCapabilities;
        cliprdr->ServerFormatList = XPServerFormatList;
        cliprdr->ServerFormatListResponse = XPServerFormatListResponse;
        cliprdr->ServerFormatDataRequest = XPServerFormatDataRequest;
        cliprdr->ServerFormatDataResponse = XPServerFormatDataResponse;
        _cliprdr = cliprdr;
        _sync = NO;
        _requestedFormatId = 0;
    }
    [_lock unlock];
    return ok;
}

- (void)detachChannel:(CliprdrClientContext *)cliprdr {
    [_lock lock];
    if (_cliprdr == cliprdr) {
        (void)cliprdr_file_context_uninit(_file, cliprdr);
        cliprdr->custom = NULL;
        _cliprdr = NULL;
        _sync = NO;
    }
    [_lock unlock];
}

/// Lock held, attached and in sync. `_text` as every text format winpr converts it to, and the files.
- (UINT)sendFormatList {
    UINT32 *ids = NULL, count = 0;
    if (_text) {
        const char *utf8 = _text.UTF8String;
        if (ClipboardSetData(_clip, ClipboardRegisterFormat(_clip, XPMimeText), utf8, (UINT32)strlen(utf8) + 1))
            count = ClipboardGetFormatIds(_clip, &ids);
    }
    CLIPRDR_FORMAT *formats = calloc(count + 1, sizeof(CLIPRDR_FORMAT));
    if (!formats) {
        free(ids);
        ClipboardEmpty(_clip);
        return CHANNEL_RC_NO_MEMORY;
    }
    UINT32 n = 0;
    for (UINT32 i = 0; i < count; i++) {
        // Names stay in the clipboard's format table, which ClipboardEmpty keeps.
        const char *name = ids[i] > CF_MAX ? ClipboardGetFormatName(_clip, ids[i]) : NULL;
        formats[n++] = (CLIPRDR_FORMAT){.formatId = ids[i], .formatName = (char *)name};
    }
    if (_uriList)
        formats[n++] = (CLIPRDR_FORMAT){.formatId = ClipboardRegisterFormat(_clip, XPFileGroupDescriptorW),
                                        .formatName = (char *)XPFileGroupDescriptorW};
    CLIPRDR_FORMAT_LIST list = {0};
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = n;
    list.formats = formats;
    UINT rc = cliprdr_file_context_notify_new_client_format_list(_file);
    if (rc == CHANNEL_RC_OK)
        rc = _cliprdr->ClientFormatList(_cliprdr, &list);
    ClipboardEmpty(_clip);
    free(formats);
    free(ids);
    return rc;
}

- (UINT)monitorReady:(CliprdrClientContext *)cliprdr {
    [_lock lock];
    CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    // The file flags only once the server offered CB_STREAM_FILECLIP_ENABLED (ServerCapabilities).
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES | cliprdr_file_context_current_flags(_file);
    CLIPRDR_CAPABILITIES capabilities = {0};
    capabilities.cCapabilitiesSets = 1;
    capabilities.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    UINT rc = cliprdr->ClientCapabilities(cliprdr, &capabilities);
    if (rc == CHANNEL_RC_OK && _cliprdr == cliprdr) {
        _sync = YES;
        rc = [self sendFormatList];
    }
    [_lock unlock];
    return rc;
}

- (UINT)serverCapabilities:(const CLIPRDR_CAPABILITIES *)capabilities {
    UINT32 flags = 0;
    const BYTE *set = (const BYTE *)capabilities->capabilitySets;
    for (UINT32 i = 0; set && i < capabilities->cCapabilitiesSets; i++) {
        const CLIPRDR_CAPABILITY_SET *caps = (const CLIPRDR_CAPABILITY_SET *)set;
        if (caps->capabilitySetType == CB_CAPSTYPE_GENERAL && caps->capabilitySetLength >= CB_CAPSTYPE_GENERAL_LEN)
            flags = ((const CLIPRDR_GENERAL_CAPABILITY_SET *)caps)->generalFlags;
        if (caps->capabilitySetLength == 0)
            break;
        set += caps->capabilitySetLength;
    }
    [_lock lock];
    const BOOL ok = cliprdr_file_context_remote_set_flags(_file, flags);
    [_lock unlock];
    return ok ? CHANNEL_RC_OK : ERROR_INTERNAL_ERROR;
}

/// The server's clipboard replaces ours: its text is fetched for the Mac pasteboard, as the Mac client did.
// shortcut: Windows → Mac files aren't offered, only text; upgrade with cliprdr_file_context_set_local_clipboard_data
// and a data callback that requests from the server and waits, as SDL's ClipDataCb does, if pasting files into Finder is wanted.
- (UINT)serverFormatList:(const CLIPRDR_FORMAT_LIST *)formatList channel:(CliprdrClientContext *)cliprdr {
    [_lock lock];
    (void)cliprdr_file_context_clear(_file);  // the server stops reading the files it had from us
    UINT rc = cliprdr_file_context_notify_new_server_format_list(_file);
    CLIPRDR_FORMAT_LIST_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = rc == CHANNEL_RC_OK ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    rc = cliprdr->ClientFormatListResponse(cliprdr, &response);

    UINT32 text = 0;  // CF_UNICODETEXT, else CF_TEXT or CF_OEMTEXT
    for (UINT32 i = 0; i < formatList->numFormats; i++) {
        const UINT32 id = formatList->formats[i].formatId;
        if (id == CF_UNICODETEXT || (!text && (id == CF_TEXT || id == CF_OEMTEXT)))
            text = id;
    }
    if (!_enabled)
        text = 0;  // the list is answered, as the protocol wants, and its data left on the server
    _requestedFormatId = text;
    if (rc == CHANNEL_RC_OK && text) {
        CLIPRDR_FORMAT_DATA_REQUEST request = {0};
        request.common.msgType = CB_FORMAT_DATA_REQUEST;
        request.requestedFormatId = text;
        rc = cliprdr->ClientFormatDataRequest(cliprdr, &request);
    }
    [_lock unlock];
    return rc;
}

/// The channel's thread, without the lock (a big folder takes a while to walk): `uriList` as a packed
/// CLIPRDR_FILELIST, its files registered for the file context to serve FileContents from.
// shortcut: one name Windows refuses (: ? * " < > |) anywhere in a copied folder fails the whole paste
// (winpr's synthesizer gives up), upgrade by setting the clipboard delegate's IsFileNameComponentValid to skip such files.
- (nullable BYTE *)copyFileList:(NSData *)uriList size:(UINT32 *)size {
    const char *list = uriList.bytes;
    const size_t length = uriList.length;
    // update_client_data keeps the stream when the list is the one it has, and replaces it otherwise.
    if (!list || length > UINT32_MAX || !cliprdr_file_context_update_client_data(_file, list, length) ||
        !ClipboardSetData(_fileClip, ClipboardRegisterFormat(_fileClip, XPMimeURIList), list, (UINT32)length))
        return NULL;
    UINT32 descriptorsSize = 0;
    FILEDESCRIPTORW *descriptors =
        ClipboardGetData(_fileClip, ClipboardRegisterFormat(_fileClip, XPFileGroupDescriptorW), &descriptorsSize);
    ClipboardEmpty(_fileClip);
    if (!descriptors)
        return NULL;
    BYTE *data = NULL;
    const UINT error = cliprdr_serialize_file_list_ex(cliprdr_file_context_remote_get_flags(_file), descriptors,
                                                      descriptorsSize / sizeof(FILEDESCRIPTORW), &data, size);
    free(descriptors);
    if (error) {
        free(data);
        *size = 0;
        return NULL;
    }
    return data;
}

- (UINT)serverFormatDataRequest:(const CLIPRDR_FORMAT_DATA_REQUEST *)request channel:(CliprdrClientContext *)cliprdr {
    [_lock lock];
    const UINT32 formatId = request->requestedFormatId;
    BYTE *data = NULL;
    UINT32 size = 0;
    NSData *uriList = nil;
    if (formatId == ClipboardRegisterFormat(_clip, XPFileGroupDescriptorW)) {
        uriList = _uriList;
    } else if (_text) {
        const char *utf8 = _text.UTF8String;
        if (ClipboardSetData(_clip, ClipboardRegisterFormat(_clip, XPMimeText), utf8, (UINT32)strlen(utf8) + 1))
            data = ClipboardGetData(_clip, formatId, &size);
        ClipboardEmpty(_clip);
    }
    [_lock unlock];
    if (uriList) {
        data = [self copyFileList:uriList size:&size];
        [_lock lock];
        if (_uriList != uriList) {  // the Mac clipboard changed meanwhile: these files aren't on offer any more
            free(data);
            data = NULL;
            if (!_text && !_uriList)
                (void)cliprdr_file_context_clear(_file);  // nothing offered (a concealed copy): no reads at all
        }
        [_lock unlock];
    }
    CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;
    response.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    response.common.dataLen = data ? size : 0;
    response.requestedFormatData = data;
    const UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
    free(data);
    return rc;
}

- (UINT)serverFormatDataResponse:(const CLIPRDR_FORMAT_DATA_RESPONSE *)response {
    [_lock lock];
    const UINT32 formatId = _requestedFormatId;
    _requestedFormatId = 0;
    NSString *text = nil;
    if (formatId && (response->common.msgFlags & CB_RESPONSE_OK) && response->requestedFormatData &&
        ClipboardSetData(_clip, formatId, response->requestedFormatData, response->common.dataLen)) {
        UINT32 size = 0;
        char *utf8 = ClipboardGetData(_clip, ClipboardRegisterFormat(_clip, XPMimeText), &size);
        if (utf8)
            text = [[NSString alloc] initWithBytes:utf8 length:strnlen(utf8, size) encoding:NSUTF8StringEncoding];
        free(utf8);
    }
    ClipboardEmpty(_clip);
    [_lock unlock];
    if (text)
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.enabled)
                return;  // switched off while this was queued
            NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
            [pasteboard clearContents];
            [pasteboard setString:text forType:NSPasteboardTypeString];
            // Announced back, this text would replace the richer copy Windows still holds (Excel cells...).
            self->_writtenChangeCount = pasteboard.changeCount;
        });
    // A failed or late reply is dropped: an error here would end the channel's thread.
    return CHANNEL_RC_OK;
}

#pragma mark Pasteboard

- (nullable NSData *)localFileURIList {
    size_t size = 0;
    char *list = _file ? cliprdr_file_context_get_local_uri_list(_file, &size) : NULL;
    return list ? [NSData dataWithBytesNoCopy:list length:size freeWhenDone:YES] : nil;
}

- (NSInteger)writtenChangeCount {
    return _writtenChangeCount;
}

- (BOOL)channelAttached {
    [_lock lock];
    const BOOL attached = _cliprdr != NULL;
    [_lock unlock];
    return attached;
}

- (BOOL)enabled {
    [_lock lock];
    const BOOL enabled = _enabled;
    [_lock unlock];
    return enabled;
}

- (void)setEnabled:(BOOL)enabled {
    [_lock lock];
    const BOOL changed = enabled != _enabled;
    _enabled = enabled;
    if (changed && !enabled) {
        _text = nil;
        _uriList = nil;
        _requestedFormatId = 0;  // a reply still on its way stays off the Mac pasteboard
        // shortcut: local_stream_discard skips locked streams and a Lock PDU isn't capability-checked, so a hostile
        // server that sent Lock first may keep reading files already offered; upgrade by failing FileContents
        // requests here while disabled if offers to untrusted servers matter.
        if (_file)
            (void)cliprdr_file_context_clear(_file);
        if (_cliprdr && _sync)
            (void)[self sendFormatList];
    }
    [_lock unlock];
    if (changed && enabled)
        _writtenChangeCount = -1;  // Windows lost its offer: the poll announces even the server's own text
}

- (XPRDPClipboardFormats)formatsToAnnounceNowForPasteboardTypes:(NSArray<NSString *> *)types {
    return self.enabled ? [XPRDPClipboard formatsToAnnounceForPasteboardTypes:types] : 0;
}

- (XPRDPClipboardFormats)lastAnnouncedFormats {
    [_lock lock];
    const XPRDPClipboardFormats formats = (_text ? XPRDPClipboardFormatsText : 0) | (_uriList ? XPRDPClipboardFormatsFiles : 0);
    [_lock unlock];
    return formats;
}

- (BOOL)offerFileURLs:(NSArray<NSURL *> *)urls {
    NSData *uriList = [XPRDPClipboard fileURIListForURLs:urls];
    [_lock lock];
    const BOOL ok = uriList && _enabled && _cliprdr;
    if (ok) {
        _text = nil;
        _uriList = uriList;
        if (_sync)
            (void)[self sendFormatList];
    }
    [_lock unlock];
    if (ok)
        _writtenChangeCount = NSPasteboard.generalPasteboard.changeCount;
    return ok;
}

- (void)offerText:(nullable NSString *)text fileURIList:(nullable NSData *)uriList {
    [_lock lock];
    if (!_enabled) {
        [_lock unlock];
        return;
    }
    _text = [text copy];
    _uriList = [uriList copy];
    // A paste Windows is reading keeps its files (it doesn't lock them: no CB_CAN_LOCK_CLIPDATA); the next
    // FileGroupDescriptorW request replaces them. With nothing on offer (a concealed copy), none can be read.
    if (_file && !_text && !_uriList)
        (void)cliprdr_file_context_clear(_file);
    if (_cliprdr && _sync)
        (void)[self sendFormatList];
    [_lock unlock];
}

@end

#pragma mark - Callbacks (the channel's thread)

static UINT XPMonitorReady(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *monitorReady) {
    XPRDPClipboard *c = XPClipboardFor(cliprdr);
    return c ? [c monitorReady:cliprdr] : ERROR_INTERNAL_ERROR;
}

static UINT XPServerCapabilities(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *capabilities) {
    XPRDPClipboard *c = XPClipboardFor(cliprdr);
    return c ? [c serverCapabilities:capabilities] : ERROR_INTERNAL_ERROR;
}

static UINT XPServerFormatList(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *formatList) {
    XPRDPClipboard *c = XPClipboardFor(cliprdr);
    return c ? [c serverFormatList:formatList channel:cliprdr] : ERROR_INTERNAL_ERROR;
}

static UINT XPServerFormatListResponse(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    return CHANNEL_RC_OK;
}

static UINT XPServerFormatDataRequest(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    XPRDPClipboard *c = XPClipboardFor(cliprdr);
    return c ? [c serverFormatDataRequest:request channel:cliprdr] : ERROR_INTERNAL_ERROR;
}

static UINT XPServerFormatDataResponse(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    XPRDPClipboard *c = XPClipboardFor(cliprdr);
    return c ? [c serverFormatDataResponse:response] : CHANNEL_RC_OK;
}
