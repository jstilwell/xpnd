#import "XPRDPFitRect.h"

CGRect XPRDPFitRect(CGSize desktop, CGRect bounds) {
    if (desktop.width <= 0 || desktop.height <= 0 || bounds.size.width <= 0 || bounds.size.height <= 0)
        return bounds;
    const CGFloat scale = MIN(bounds.size.width / desktop.width, bounds.size.height / desktop.height);
    const CGSize size = CGSizeMake(desktop.width * scale, desktop.height * scale);
    return CGRectMake(bounds.origin.x + (bounds.size.width - size.width) / 2,
                      bounds.origin.y + (bounds.size.height - size.height) / 2, size.width, size.height);
}
