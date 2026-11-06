#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Points per desktop pixel, as the desktop is drawn in its tab. A pointer from the server is in desktop pixels,
/// so it needs the same scale as the image: 0.5 for a Retina desktop. 1 when either size is empty.
CGFloat XPRDPCursorScale(CGSize desktop, CGRect drawn) NS_SWIFT_NAME(XPRDPCursorScale(desktop:drawn:));

/// A copy of `cursor`'s bitmap with its own pixels, or nil if it has no bitmap: FreeRDP frees a pointer's pixels with
/// the pointer, whatever still holds its `NSCursor`.
NSBitmapImageRep *_Nullable XPRDPOwnedBitmap(NSCursor *cursor);

/// `bitmap` as a cursor at `scale` points per pixel, with every pixel kept so it is sharp on Retina.
NSCursor *XPRDPScaledCursor(NSBitmapImageRep *bitmap, NSPoint hotSpot, CGFloat scale);

NS_ASSUME_NONNULL_END
