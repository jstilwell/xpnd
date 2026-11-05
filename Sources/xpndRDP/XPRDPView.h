// FreeRDP and winpr before Cocoa (MRDPView.h imports Cocoa first): see XPRDPVersion.m.
#include <winpr/windows.h>
#include <freerdp/freerdp.h>
#import <freerdp/client/Mac/MRDPView.h>

#import "XPRDPClipboard+Channel.h"
#import "XPRDPSession.h"

NS_ASSUME_NONNULL_BEGIN


/// FreeRDP's Mac view made fit for a tab: mouse coordinates relative to the view and scaled to the
/// desktop, display-control resizes, a drawing lock, the clipboard guard and the ⌘ key mapping.
@interface XPRDPView : MRDPView
@property (weak, nullable) XPRDPSession *session;
/// The clipboard channel's xpnd side, fed by the pasteboard poll.
@property (readonly) XPRDPClipboard *clipboard;
@property BOOL commandAsWindowsKey;
/// A fixed-size desktop keeps its aspect ratio, letterboxed in black; otherwise (resized to fit) it fills the view.
/// Main thread.
@property (nonatomic) BOOL letterbox;

/// Held while FreeRDP's thread swaps the desktop image (connect, resize, disconnect) and while drawing.
- (void)lockDrawing;
- (void)unlockDrawing;
/// FreeRDP's thread, before gdi_free: the image points into the GDI buffer.
- (void)dropDesktopImage;
/// Main thread, once the client thread has exited and before the context is freed.
- (void)detachContext;
/// Main thread: `rect` is in desktop pixels with a top-left origin.
- (void)invalidateDesktopRect:(NSRect)rect desktopSize:(NSSize)desktopSize;
/// Main thread, before the client thread starts: clears the ⌘ state and restores mouse tracking.
- (void)prepareForConnection;
/// Main thread: `scancode` in FreeRDP's encoding (KBDEXT for extended keys). Nothing without a connection.
- (void)sendScancode:(DWORD)scancode down:(BOOL)down;
/// Main thread: each UTF-16 unit as a Unicode key press.
- (void)sendText:(NSString *)text;
/// Main thread: one left click at `point`, in the view's coordinates.
- (void)sendLeftClickAtViewPoint:(NSPoint)point;
/// Main thread: xpnd took the ⌘ being held, so its release isn't a tap of the Windows key.
- (void)noteCommandUsed;
/// Main thread: the clipboard's switch; on again, the poll announces what the pasteboard holds now.
- (void)setClipboardSyncEnabled:(BOOL)enabled;
@end

@interface XPRDPSession (XPRDPView)
/// Main thread, once a live resize has settled.
- (void)viewSizeSettled:(CGSize)size;
/// Main thread: connected, and not stopped.
@property (readonly) BOOL live;
@end

NS_ASSUME_NONNULL_END
