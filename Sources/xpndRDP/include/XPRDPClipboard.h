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
@end

NS_ASSUME_NONNULL_END
