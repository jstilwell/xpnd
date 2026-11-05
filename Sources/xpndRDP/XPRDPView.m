#import "XPRDPView.h"  // FreeRDP's headers first; see XPRDPView.h

#import <freerdp/client/Mac/Clipboard.h>

#import "XPRDPClipboardFilter.h"
#import "XPRDPFitRect.h"
#import "XPRDPResizeCoalescer.h"

/// Where ⌘ stands while it is held: nothing sent yet, used by xpnd (a shortcut or ⌘-click, so its release
/// isn't a bare tap), or sent as the Windows key or as Ctrl.
typedef NS_ENUM(NSInteger, XPCommandState) { XPCommandUp, XPCommandPending, XPCommandUsed, XPCommandWindows, XPCommandControl };

static const NSEventModifierFlags XPCommandFlag = NSEventModifierFlagCommand;

// RDP_SCANCODE_LWIN and RDP_SCANCODE_LCONTROL, spelled out: their TRUE/FALSE clash with CoreFoundation's
// under modules (-Wambiguous-macro).
static const DWORD XPScancodeLeftWindows = 0x5B | KBDEXT;
static const DWORD XPScancodeLeftControl = 0x1D;

/// ⌘C/⌘V/⌘X/⌘Z/⌘A (Shift allowed, as in ⌘⇧Z): the shortcuts Windows knows as Ctrl+key.
static BOOL XPIsEditShortcut(NSEvent *event) {
    const NSEventModifierFlags flags = event.modifierFlags;
    if (!(flags & XPCommandFlag) || (flags & (NSEventModifierFlagControl | NSEventModifierFlagOption)))
        return NO;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    return key.length == 1 && [@"cvxza" containsString:key];
}

@implementation XPRDPView {
    NSRecursiveLock *_drawLock;
    XPRDPResizeCoalescer *_coalescer;
    NSTrackingArea *_tracking;
    XPCommandState _command;
    NSTimer *_clipboardPoll;  // main thread
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _drawLock = [NSRecursiveLock new];
        _commandAsWindowsKey = YES;
        __weak XPRDPView *weakSelf = self;
        _coalescer = [[XPRDPResizeCoalescer alloc] initWithIdleInterval:0.2 handler:^(CGSize size) {
            [weakSelf.session viewSizeSettled:size];
        }];
    }
    return self;
}

#pragma mark Drawing

- (void)lockDrawing {
    [_drawLock lock];
}

- (void)unlockDrawing {
    [_drawLock unlock];
}

/// The one rectangle drawing, invalidation and mouse mapping use for the desktop, in view points.
- (NSRect)desktopRectForSize:(NSSize)desktop {
    return _letterbox ? XPRDPFitRect(desktop, self.bounds) : self.bounds;
}

/// MRDPView's, drawn into `desktopRectForSize:` instead of the bounds.
- (void)drawRect:(NSRect)rect {
    [_drawLock lock];
    [NSColor.blackColor setFill];
    NSRectFill(rect);
    CGImageRef image = context && bitmap_context ? CGBitmapContextCreateImage(bitmap_context) : NULL;
    if (image) {
        const NSRect target = [self desktopRectForSize:NSMakeSize(CGImageGetWidth(image), CGImageGetHeight(image))];
        CGContextRef cg = NSGraphicsContext.currentContext.CGContext;
        CGContextSaveGState(cg);
        CGContextClipToRect(cg, rect);
        CGContextDrawImage(cg, target, image);
        CGContextRestoreGState(cg);
        CGImageRelease(image);
    }
    [_drawLock unlock];
}

- (void)dropDesktopImage {
    [_drawLock lock];
    CGContextRelease(bitmap_context);
    bitmap_context = NULL;
    [_drawLock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.needsDisplay = YES;
    });
}

- (void)detachContext {
    [self dropDesktopImage];
    [_drawLock lock];
    context = NULL;
    instance = NULL;
    mfc = NULL;
    [_drawLock unlock];
    self.is_connected = 0;
    [_clipboardPoll invalidate];
    _clipboardPoll = nil;
}

#pragma mark Connection

// MRDPView's resume returns at once, because the client thread only sets is_connected after
// freerdp_connect (which runs PostConnect, and so resume) returns: its clipboard poll never starts.
// Its pause messages a timer ivar MRR code left unretained. Both are replaced, and neither calls super.

/// FreeRDP's thread, from mac_post_connect.
- (void)resume {
    if (instance && instance->context)
        (void)freerdp_input_send_focus_in_event(instance->context->input, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->kbdModFlags = 0;
        [self->_clipboardPoll invalidate];
        __weak XPRDPView *weakSelf = self;
        self->_clipboardPoll = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            [weakSelf onPasteboardTimerFired:timer];
        }];
    });
}

/// FreeRDP's thread, from mac_post_disconnect.
- (void)pause {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->kbdModFlags = 0;
        [self->_clipboardPoll invalidate];
        self->_clipboardPoll = nil;
    });
}

- (void)invalidateDesktopRect:(NSRect)rect desktopSize:(NSSize)desktopSize {
    if (desktopSize.width < 1 || desktopSize.height < 1)
        return;
    const NSRect b = [self desktopRectForSize:desktopSize];
    const CGFloat sx = b.size.width / desktopSize.width, sy = b.size.height / desktopSize.height;
    const NSRect r = NSMakeRect(b.origin.x + rect.origin.x * sx, NSMaxY(b) - (rect.origin.y + rect.size.height) * sy,
                                rect.size.width * sx, rect.size.height * sy);
    [self setNeedsDisplayInRect:NSInsetRect(r, -1, -1)];
}

#pragma mark Size

- (void)setFrameSize:(NSSize)size {
    if (!NSThread.isMainThread) {
        // MRDPView's desktop resize sizes the view to the desktop from FreeRDP's thread. The tab owns
        // the frame; the image is scaled to it instead.
        dispatch_async(dispatch_get_main_queue(), ^{
            self.needsDisplay = YES;
        });
        return;
    }
    [super setFrameSize:size];
    self.needsDisplay = YES;  // the whole image is rescaled, and the letterbox moves
    [_coalescer noteSize:size];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [_coalescer noteSize:self.bounds.size];  // the desktop is in pixels when Retina is on
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    if (self.window)
        [center addObserver:self selector:@selector(windowDidResignKey:) name:NSWindowDidResignKeyNotification object:self.window];
}

- (void)prepareForConnection {
    _command = XPCommandUp;
    [self updateTrackingAreas];
}

#pragma mark Mouse

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    // MRDPView's own areas have a fixed rect and its `pause` removes every area, so keep one that follows the view.
    if (_tracking && [self.trackingAreas containsObject:_tracking])
        return;
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                             options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow |
                                                     NSTrackingInVisibleRect | NSTrackingEnabledDuringMouseDrag
                                               owner:self
                                            userInfo:nil];
    [self addTrackingArea:_tracking];
}

/// MRDPView takes `locationInWindow` as view coordinates and the view's points as desktop pixels;
/// in a tab neither holds. Map proportionally within the drawn image; the letterbox clamps to its edge.
- (BOOL)desktopPointForEvent:(NSEvent *)event x:(UINT16 *)x y:(UINT16 *)y {
    if (!self.is_connected || !context)
        return NO;
    const UINT32 dw = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 dh = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    const NSRect b = [self desktopRectForSize:NSMakeSize(dw, dh)];
    if (b.size.width < 1 || b.size.height < 1 || dw == 0 || dh == 0)
        return NO;
    const NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    const double fx = (p.x - b.origin.x) / b.size.width * dw, fy = (1.0 - (p.y - b.origin.y) / b.size.height) * dh;
    *x = (UINT16)MIN(MAX(fx, 0.0), (double)(dw - 1));
    *y = (UINT16)MIN(MAX(fy, 0.0), (double)(dh - 1));
    return YES;
}

- (void)sendMouse:(NSEvent *)event flags:(UINT16)flags {
    UINT16 x = 0, y = 0;
    if ([self desktopPointForEvent:event x:&x y:&y])
        (void)freerdp_client_send_button_event(&mfc->common, NO, flags, x, y);
}

/// Buttons 0–2 are left, right, middle; 3 and 4 the side buttons.
- (void)sendButton:(NSInteger)button event:(NSEvent *)event down:(BOOL)down {
    UINT16 x = 0, y = 0;
    if (![self desktopPointForEvent:event x:&x y:&y])
        return;
    if (button <= 2) {
        const UINT16 which = button == 0 ? PTR_FLAGS_BUTTON1 : button == 1 ? PTR_FLAGS_BUTTON2 : PTR_FLAGS_BUTTON3;
        (void)freerdp_client_send_button_event(&mfc->common, NO, which | (down ? PTR_FLAGS_DOWN : 0), x, y);
    } else if (button <= 4) {
        const UINT16 which = button == 3 ? PTR_XFLAGS_BUTTON1 : PTR_XFLAGS_BUTTON2;
        (void)freerdp_client_send_extended_button_event(&mfc->common, NO, which | (down ? PTR_XFLAGS_DOWN : 0), x, y);
    }
}

- (void)mouseMoved:(NSEvent *)event { [self sendMouse:event flags:PTR_FLAGS_MOVE]; }
- (void)mouseDragged:(NSEvent *)event { [self sendMouse:event flags:PTR_FLAGS_MOVE]; }
- (void)rightMouseDragged:(NSEvent *)event { [self sendMouse:event flags:PTR_FLAGS_MOVE]; }
- (void)otherMouseDragged:(NSEvent *)event { [self sendMouse:event flags:PTR_FLAGS_MOVE]; }
- (void)mouseDown:(NSEvent *)event {
    if (_command == XPCommandPending)
        _command = XPCommandUsed;  // ⌘-click
    [self sendButton:0 event:event down:YES];
}
- (void)mouseUp:(NSEvent *)event { [self sendButton:0 event:event down:NO]; }
- (void)rightMouseDown:(NSEvent *)event { [self sendButton:1 event:event down:YES]; }
- (void)rightMouseUp:(NSEvent *)event { [self sendButton:1 event:event down:NO]; }
- (void)otherMouseDown:(NSEvent *)event { [self sendButton:event.buttonNumber event:event down:YES]; }
- (void)otherMouseUp:(NSEvent *)event { [self sendButton:event.buttonNumber event:event down:NO]; }

- (void)scrollWheel:(NSEvent *)event {
    // MRDPView's units and steps, sent at the pointer rather than at (0, height).
    const CGFloat dx = event.deltaX, dy = event.deltaY;
    UINT16 flags, units;
    if (fabs(dy) > FLT_EPSILON) {
        flags = PTR_FLAGS_WHEEL | (dy < 0 ? PTR_FLAGS_WHEEL_NEGATIVE : 0);
        units = (UINT16)MIN(fabs(dy) * 120, 0xFF);
    } else if (fabs(dx) > FLT_EPSILON) {
        flags = PTR_FLAGS_HWHEEL | (dx > 0 ? PTR_FLAGS_WHEEL_NEGATIVE : 0);
        units = (UINT16)MIN(fabs(dx) * 120, 0xFF);
    } else {
        return;
    }
    if (flags & PTR_FLAGS_WHEEL_NEGATIVE)
        units = 0x100 - units;  // 9-bit two's complement
    [self sendMouse:event flags:flags | (units & 0x1FF)];
}

#pragma mark Keyboard

- (void)sendScancode:(DWORD)scancode down:(BOOL)down {
    if (!instance || !instance->context)
        return;
    const UINT16 flags = (down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE) | (scancode & KBDEXT);
    (void)freerdp_input_send_keyboard_event(instance->context->input, flags, (UINT8)(scancode & 0xFF));
}

- (void)setCommandState:(XPCommandState)next {
    if (_command == next)
        return;
    if (_command == XPCommandWindows) [self sendScancode:XPScancodeLeftWindows down:NO];
    if (_command == XPCommandControl) [self sendScancode:XPScancodeLeftControl down:NO];
    if (next == XPCommandWindows) [self sendScancode:XPScancodeLeftWindows down:YES];
    if (next == XPCommandControl) [self sendScancode:XPScancodeLeftControl down:YES];
    _command = next;
}

- (void)flagsChanged:(NSEvent *)event {
    if (self.is_connected) {
        const BOOL down = (event.modifierFlags & XPCommandFlag) != 0;
        if (down && _command == XPCommandUp) {
            _command = XPCommandPending;  // decided by the next key
        } else if (!down && _command != XPCommandUp) {
            if (_command == XPCommandPending && _commandAsWindowsKey) {
                // ⌘ alone taps the Windows key, which opens Start.
                [self sendScancode:XPScancodeLeftWindows down:YES];
                [self sendScancode:XPScancodeLeftWindows down:NO];
            }
            [self setCommandState:XPCommandUp];
        }
        // Hide ⌘ from MRDPView, which would send the Windows key the moment it goes down.
        kbdModFlags = (kbdModFlags & ~(DWORD)XPCommandFlag) | (DWORD)(event.modifierFlags & XPCommandFlag);
    }
    [super flagsChanged:event];
}

- (void)keyDown:(NSEvent *)event {
    const BOOL command = self.is_connected && (event.modifierFlags & XPCommandFlag);
    if (command) {
        const BOOL control = XPIsEditShortcut(event) || !_commandAsWindowsKey;
        [self setCommandState:control ? XPCommandControl : XPCommandWindows];
    }
    [super keyDown:event];
    if (command)
        [super keyUp:event];  // AppKit doesn't deliver keyUp: while ⌘ is held
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    const BOOL focused = self.is_connected && self.window.firstResponder == self;
    // Otherwise xpnd's Edit menu takes ⌘C/⌘V/⌘X/⌘Z/⌘A before Windows sees them.
    if (focused && XPIsEditShortcut(event)) {
        [self keyDown:event];
        return YES;
    }
    // Another ⌘ shortcut is xpnd's (⌘1, ⌘⇧]...); if nothing takes it, keyDown: sends it on as before.
    if (focused && _command == XPCommandPending)
        _command = XPCommandUsed;
    return [super performKeyEquivalent:event];
}

/// Every modifier Windows holds down is released; Caps Lock and Num Lock, which toggle, are left alone.
- (void)releaseModifiers {
    [self setCommandState:XPCommandUp];
    kbdModFlags &= ~(DWORD)XPCommandFlag;  // ⌘ is ours, released above
    const NSEventModifierFlags toggles = NSEventModifierFlagCapsLock | NSEventModifierFlagNumericPad;
    NSEvent *up = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:kbdModFlags & toggles
                                  timestamp:0 windowNumber:0 context:nil characters:@"" charactersIgnoringModifiers:@""
                                  isARepeat:NO keyCode:0];
    if (up)
        [super flagsChanged:up];  // MRDPView sends the key-ups for what it had down
    kbdModFlags &= (DWORD)toggles;
}

- (void)windowDidResignKey:(NSNotification *)note {
    [self releaseModifiers];  // ⌘-Tab away: the releases go elsewhere
}

- (void)viewWillMoveToWindow:(NSWindow *)window {
    [self releaseModifiers];  // another tab: the releases go to it
    [super viewWillMoveToWindow:window];
}

- (BOOL)resignFirstResponder {
    [self releaseModifiers];
    return [super resignFirstResponder];
}

#pragma mark Clipboard

/// Replaces MRDPView's poll: never offers a concealed or xpnd-secret item, reads every item's types,
/// and drops a read the pasteboard changed under.
- (void)onPasteboardTimerFired:(NSTimer *)timer {
    mfContext *m = mfc;
    if (!m)
        return;
    NSPasteboard *pasteboard = pasteboard_rd;
    const NSInteger changeCount = pasteboard.changeCount;
    if (!pasteboard || changeCount == pasteboard_changecount)
        return;
    NSArray<NSPasteboardItem *> *items = pasteboard.pasteboardItems;
    NSMutableArray<NSString *> *types = [NSMutableArray array];
    for (NSPasteboardItem *item in items)
        [types addObjectsFromArray:item.types];
    NSString *text = [XPRDPClipboardFilter shouldOfferPasteboardTypes:types] ? [items.firstObject stringForType:NSPasteboardTypeString] : nil;
    if (pasteboard.changeCount != changeCount)
        return;  // the next tick reads the newer contents
    pasteboard_changecount = (int)changeCount;
    if (!m->clipboard)
        return;
    if (text) {
        const char *utf8 = text.UTF8String;
        const UINT32 format = ClipboardRegisterFormat(m->clipboard, "text/plain;charset=utf-8");
        (void)ClipboardSetData(m->clipboard, format, utf8, (UINT32)strlen(utf8) + 1);
    } else {
        ClipboardEmpty(m->clipboard);
    }
    if (m->clipboardSync)
        (void)mac_cliprdr_send_client_format_list(m->cliprdr);
}

@end
