// FreeRDP's headers come before Foundation's: with modules on, CoreFoundation's CFPlugInCOM typedefs
// REFIID differently from winpr, and only this order compiles.
#include <freerdp/freerdp.h>

#import "XPRDPVersion.h"

@implementation XPRDPVersion

+ (NSString *)freerdpVersion {
    return [NSString stringWithUTF8String:freerdp_get_version_string()];
}

@end
