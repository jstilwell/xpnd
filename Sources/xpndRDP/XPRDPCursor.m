#import "XPRDPCursor.h"

CGFloat XPRDPCursorScale(CGSize desktop, CGRect drawn) {
    if (desktop.width <= 0 || drawn.size.width <= 0)
        return 1;
    return drawn.size.width / desktop.width;
}

NSBitmapImageRep *XPRDPOwnedBitmap(NSCursor *cursor) {
    NSImageRep *rep = cursor.image.representations.firstObject;
    if (![rep isKindOfClass:NSBitmapImageRep.class])
        return nil;
    // Through TIFF, as `copy` may keep pointing at planes it was given.
    return [NSBitmapImageRep imageRepWithData:((NSBitmapImageRep *)rep).TIFFRepresentation];
}

NSCursor *XPRDPScaledCursor(NSBitmapImageRep *bitmap, NSPoint hotSpot, CGFloat scale) {
    NSBitmapImageRep *rep = [bitmap copy];
    rep.size = NSMakeSize(bitmap.pixelsWide * scale, bitmap.pixelsHigh * scale);
    NSImage *image = [[NSImage alloc] initWithSize:rep.size];
    [image addRepresentation:rep];
    return [[NSCursor alloc] initWithImage:image hotSpot:NSMakePoint(hotSpot.x * scale, hotSpot.y * scale)];
}
