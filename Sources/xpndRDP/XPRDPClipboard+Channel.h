// FreeRDP and winpr before Cocoa: see XPRDPVersion.m.
#include <freerdp/client/cliprdr.h>

#import "XPRDPClipboard.h"

NS_ASSUME_NONNULL_BEGIN

/// One per view. The channel's callbacks come on FreeRDP's threads, the pasteboard from main; a lock
/// serialises them, and nothing is kept in the winpr clipboard between calls (it only converts).
@interface XPRDPClipboard (Channel)
/// FreeRDP's thread, when the cliprdr channel connects: installs every callback, its own and the file
/// context's (lock, unlock, FileContents).
- (BOOL)attachChannel:(CliprdrClientContext *)cliprdr;
/// FreeRDP's thread, when the channel disconnects (before it is freed).
- (void)detachChannel:(CliprdrClientContext *)cliprdr;
/// Main thread: the general pasteboard's files as a text/uri-list (no NUL), or nil. Call only once the
/// pasteboard passed `formatsToAnnounceForPasteboardTypes:`, as it reads the pasteboard itself.
- (nullable NSData *)localFileURIList;
/// Main thread: what the Mac clipboard now offers, nil for none. Announced at once if the channel is
/// ready, otherwise when the server says it is (MonitorReady).
- (void)offerText:(nullable NSString *)text fileURIList:(nullable NSData *)uriList;
@end

NS_ASSUME_NONNULL_END
