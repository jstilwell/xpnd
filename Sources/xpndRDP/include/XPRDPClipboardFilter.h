#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Decides whether the Mac clipboard may be offered to the remote desktop.
@interface XPRDPClipboardFilter : NSObject
/// NO when any type is `org.nspasteboard.ConcealedType` or starts with xpnd's secret tag
/// `com.jessestilwell.xpnd.secret` (`SecretClipboard.secretTypePrefix`; each copy appends `.<UUID>`).
+ (BOOL)shouldOfferPasteboardTypes:(NSArray<NSString *> *)types;
/// YES for an offerable pasteboard marked `org.nspasteboard.TransientType`, as a snippet's paste is: it is put
/// back within a moment, so it is neither offered nor a reason to withdraw what is on offer. A concealed
/// item is transient too, and that one is withdrawn, so this is NO for it.
+ (BOOL)shouldIgnorePasteboardTypes:(NSArray<NSString *> *)types;
@end

NS_ASSUME_NONNULL_END
