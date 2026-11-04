// FreeRDP and winpr before Cocoa (MRDPView.h imports Cocoa first): see XPRDPVersion.m.
#include <winpr/windows.h>
#include <freerdp/freerdp.h>
#import <freerdp/client/Mac/MRDPView.h>

#import "XPRDPSession.h"

NS_ASSUME_NONNULL_BEGIN


/// FreeRDP's Mac view made fit for a tab: mouse coordinates relative to the view and scaled to the
/// desktop, display-control resizes, a drawing lock, the clipboard guard and the ⌘ key mapping.
@interface XPRDPView : MRDPView
@property (weak, nullable) XPRDPSession *session;
@property BOOL commandAsWindowsKey;
/// A fixed-size desktop keeps its aspect ratio, letterboxed in black; otherwise (resized to fit) it fills the view.
/// Main thread, before the client thread starts.
@property BOOL letterbox;

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
@end

@interface XPRDPSession (XPRDPView)
/// Main thread, once a live resize has settled.
- (void)viewSizeSettled:(CGSize)size;
@end

NS_ASSUME_NONNULL_END
