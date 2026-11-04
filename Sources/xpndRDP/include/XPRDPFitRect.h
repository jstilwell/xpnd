#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

/// Where a desktop of `desktop` pixels is drawn in `bounds`: as large as fits with its aspect ratio
/// kept, centred (the rest is letterbox). `bounds` itself when either size is empty.
CGRect XPRDPFitRect(CGSize desktop, CGRect bounds) NS_SWIFT_NAME(XPRDPFitRect(desktop:in:));
