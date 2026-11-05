#import <Foundation/Foundation.h>

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

/// YES by default. NO clears what is on offer (the server gets an empty format list), and from then on
/// nothing is offered and the server's lists are answered but not fetched, until set back to YES.
@property BOOL enabled;
/// The class method's answer, or nothing while disabled.
- (XPRDPClipboardFormats)formatsToAnnounceNowForPasteboardTypes:(NSArray<NSString *> *)types;
/// Main thread: what the Mac clipboard now offers, nil for none. Announced at once if the channel is
/// ready, otherwise when the server says it is (MonitorReady). Nothing while disabled.
- (void)offerText:(nullable NSString *)text fileURIList:(nullable NSData *)uriList;
/// Main thread: offers these files alone, as a Finder copy would, without touching the pasteboard. The offer
/// stands until the pasteboard next changes. NO when disabled, with no channel, or for no file URLs.
- (BOOL)offerFileURLs:(NSArray<NSURL *> *)urls;
/// Test hook: what is on offer now.
@property (readonly) XPRDPClipboardFormats lastAnnouncedFormats;
@end

NS_ASSUME_NONNULL_END
