#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// What the Mac clipboard is offered to the remote desktop as.
typedef NS_OPTIONS(NSUInteger, XPRDPClipboardFormats) {
    XPRDPClipboardFormatsText = 1 << 0,   // CF_UNICODETEXT and the other text formats
    XPRDPClipboardFormatsFiles = 1 << 1,  // FileGroupDescriptorW, with FileContents served from the local files
};

/// xpnd's side of an RDP session's clipboard channel (cliprdr), in place of FreeRDP's Mac client's.
@interface XPRDPClipboard : NSObject
/// Nothing for a concealed or xpnd-secret pasteboard (`XPRDPClipboardFilter`); otherwise text for a
/// string, files for file URLs (`public.file-url`, `NSFilenamesPboardType`), or both.
+ (XPRDPClipboardFormats)formatsToAnnounceForPasteboardTypes:(NSArray<NSString *> *)types;
/// `urls`' file URLs as the text/uri-list a Finder copy gives; nil when there are none.
+ (nullable NSData *)fileURIListForURLs:(NSArray<NSURL *> *)urls;
/// The file URLs on `pasteboard`, and no others.
+ (NSArray<NSURL *> *)fileURLsOnPasteboard:(NSPasteboard *)pasteboard;

/// YES by default. NO clears what is on offer (the server gets an empty format list), and from then on
/// nothing is offered and the server's lists are answered but not fetched, until set back to YES.
@property BOOL enabled;
/// The class method's answer, or nothing while disabled.
- (XPRDPClipboardFormats)formatsToAnnounceNowForPasteboardTypes:(NSArray<NSString *> *)types;
/// Main thread: what the Mac clipboard now offers, nil for none. Announced at once if the channel is
/// ready, otherwise when the server says it is (MonitorReady). Nothing while disabled.
- (void)offerText:(nullable NSString *)text fileURIList:(nullable NSData *)uriList;
/// Main thread: offers these files alone, as a Finder copy would, without touching the pasteboard. The offer
/// stands until the pasteboard next changes. `completion` runs once, on the main queue: YES when the server's
/// Format List Response accepts this list, so a paste will get these files. NO on a failure response, after
/// `offerTimeout`, when the session ends, when something newer replaces the offer on either side, and at once
/// when disabled, not yet in sync with the server, with no channel, or for no file URLs.
- (void)offerFileURLs:(NSArray<NSURL *> *)urls completion:(void (^)(BOOL accepted))completion;
/// Seconds an offer waits for the server; 2 by default, shorter in tests.
@property NSTimeInterval offerTimeout;
/// Test hook: what is on offer now.
@property (readonly) XPRDPClipboardFormats lastAnnouncedFormats;
/// Test hooks: a stand-in cliprdr channel with no server behind it. Detach what you attach.
- (void)attachTestChannel;
- (void)detachTestChannel;
/// Test hooks: what a server would send: MonitorReady, a Format List Response, a format list with nothing in it.
- (void)testServerReady;
- (void)testServerAnswersFormatList:(BOOL)ok;
- (void)testServerSendsFormatList;
/// Test hook: the format lists that went out on the stand-in channel.
@property (readonly) NSUInteger testListsOnWire;
@end

NS_ASSUME_NONNULL_END
