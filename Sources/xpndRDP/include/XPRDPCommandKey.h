#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Where ⌘ stands while it is held: nothing sent yet, used by xpnd (a shortcut or ⌘-click, so its release
/// isn't a bare tap), or sent as the Windows key or as Ctrl.
typedef NS_ENUM(NSInteger, XPCommandState) { XPCommandUp, XPCommandPending, XPCommandUsed, XPCommandWindows, XPCommandControl };

/// ⌘ went down or up. `otherModifiers`: Shift, Control or Option held with it, a shortcut in the making that macOS
/// may keep to itself (⌘⇧4), so no key ever says so. `tapWindows` is set when ⌘ was released alone and should tap
/// the Windows key, which opens Start.
XPCommandState XPCommandAfterFlags(XPCommandState state, BOOL commandDown, BOOL otherModifiers, BOOL asWindowsKey,
                                   BOOL *tapWindows);
/// A key went down with ⌘ held: Ctrl for an edit shortcut, or for every key when ⌘ isn't the Windows key.
XPCommandState XPCommandAfterKey(XPCommandState state, BOOL editShortcut, BOOL asWindowsKey);
/// xpnd took the ⌘ being held (a ⌘-click, a scroll, a menu's shortcut).
XPCommandState XPCommandAfterUse(XPCommandState state);

/// ⌘C/⌘V/⌘X/⌘Z/⌘A (Shift allowed, as in ⌘⇧Z): the shortcuts Windows knows as Ctrl+key. On a layout whose keys
/// aren't Latin (Russian, Greek), `characters` is "с", so the key's position decides, as macOS's own ⌘ shortcuts do.
BOOL XPIsEditShortcutKey(NSString *charactersIgnoringModifiers, unsigned short keyCode, NSEventModifierFlags flags);

/// The RDP pointer flags for a scroll of `dx`, `dy` (AppKit's deltas, lines), or 0 when there is nothing to send:
/// no movement, or less than a 120th of a line.
uint16_t XPWheelFlags(CGFloat dx, CGFloat dy);

NS_ASSUME_NONNULL_END
