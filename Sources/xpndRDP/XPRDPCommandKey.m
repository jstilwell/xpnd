// FreeRDP and winpr before Cocoa: see XPRDPVersion.m.
#include <freerdp/input.h>

#import "XPRDPCommandKey.h"

XPCommandState XPCommandAfterUse(XPCommandState state) {
    return state == XPCommandPending ? XPCommandUsed : state;
}

XPCommandState XPCommandAfterFlags(XPCommandState state, BOOL commandDown, BOOL otherModifiers, BOOL asWindowsKey,
                                   BOOL *tapWindows) {
    *tapWindows = NO;
    if (commandDown && state == XPCommandUp) {
        state = XPCommandPending;  // decided by the next key
    } else if (!commandDown && state != XPCommandUp) {
        *tapWindows = state == XPCommandPending && asWindowsKey;
        state = XPCommandUp;
    }
    return commandDown && otherModifiers ? XPCommandAfterUse(state) : state;
}

XPCommandState XPCommandAfterKey(XPCommandState state, BOOL editShortcut, BOOL asWindowsKey) {
    return editShortcut || !asWindowsKey ? XPCommandControl : XPCommandWindows;
}

BOOL XPIsEditShortcutKey(NSString *charactersIgnoringModifiers, unsigned short keyCode, NSEventModifierFlags flags) {
    if (!(flags & NSEventModifierFlagCommand) || (flags & (NSEventModifierFlagControl | NSEventModifierFlagOption)))
        return NO;
    NSString *key = charactersIgnoringModifiers.lowercaseString;
    if (key.length == 1 && [key characterAtIndex:0] < 0x80)
        return [@"cvxza" containsString:key];
    // kVK_ANSI_C, V, X, Z and A.
    return keyCode == 8 || keyCode == 9 || keyCode == 7 || keyCode == 6 || keyCode == 0;
}

uint16_t XPWheelFlags(CGFloat dx, CGFloat dy) {
    // MRDPView's units and steps.
    uint16_t flags, units;
    if (fabs(dy) > FLT_EPSILON) {
        flags = PTR_FLAGS_WHEEL | (dy < 0 ? PTR_FLAGS_WHEEL_NEGATIVE : 0);
        units = (uint16_t)MIN(fabs(dy) * 120, 0xFF);
    } else if (fabs(dx) > FLT_EPSILON) {
        flags = PTR_FLAGS_HWHEEL | (dx > 0 ? PTR_FLAGS_WHEEL_NEGATIVE : 0);
        units = (uint16_t)MIN(fabs(dx) * 120, 0xFF);
    } else {
        return 0;
    }
    if (units == 0)
        return 0;  // under 1/120 (a momentum tail): negated, 0 would be 0x100, a step of -256
    if (flags & PTR_FLAGS_WHEEL_NEGATIVE)
        units = 0x100 - units;  // 9-bit two's complement
    return flags | (units & 0x1FF);
}
