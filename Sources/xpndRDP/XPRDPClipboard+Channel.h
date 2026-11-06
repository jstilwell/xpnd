// FreeRDP and winpr before Cocoa: see XPRDPVersion.m.
#include <freerdp/client/cliprdr.h>

#import "XPRDPClipboard.h"

NS_ASSUME_NONNULL_BEGIN

/// One per view. The channel's callbacks come on FreeRDP's threads, the pasteboard from main; a lock
/// serialises them. The winpr clipboards only convert: no data stays in them between calls, though winpr
/// keeps the last file list's paths (its `localFiles`) until the next conversion.
@interface XPRDPClipboard (Channel)
/// FreeRDP's thread, when the cliprdr channel connects: installs every callback, its own and the file
/// context's (lock, unlock, FileContents).
- (BOOL)attachChannel:(CliprdrClientContext *)cliprdr;
/// FreeRDP's thread, when the channel disconnects (before it is freed).
- (void)detachChannel:(CliprdrClientContext *)cliprdr;
/// Main thread: the general pasteboard's files as a text/uri-list (no NUL), or nil. Call only once the
/// pasteboard passed `formatsToAnnounceForPasteboardTypes:`, as it reads the pasteboard itself.
- (nullable NSData *)localFileURIList;
/// Main thread: the pasteboard's changeCount the poll skips: after it wrote the server's text there, or
/// when a file offer took over from what the pasteboard holds.
@property (readonly) NSInteger writtenChangeCount;
/// YES while the cliprdr channel is connected.
@property (readonly) BOOL channelAttached;
@end

NS_ASSUME_NONNULL_END
