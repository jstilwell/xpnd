#import "XPRDPClipboardFilter.h"

@implementation XPRDPClipboardFilter

+ (BOOL)shouldOfferPasteboardTypes:(NSArray<NSString *> *)types {
    for (NSString *type in types) {
        if ([type isEqualToString:@"org.nspasteboard.ConcealedType"] || [type hasPrefix:@"com.jessestilwell.xpnd.secret"])
            return NO;
    }
    return YES;
}

+ (BOOL)shouldIgnorePasteboardTypes:(NSArray<NSString *> *)types {
    return [types containsObject:@"org.nspasteboard.TransientType"] && [self shouldOfferPasteboardTypes:types];
}

@end
