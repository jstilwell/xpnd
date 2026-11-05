#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Collapses a burst of sizes (a live window resize) into one call with the last size.
@interface XPRDPResizeCoalescer : NSObject
/// `handler` runs on the main queue.
- (instancetype)initWithIdleInterval:(NSTimeInterval)seconds handler:(void (^)(CGSize size))handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// The handler fires once with the last size after `seconds` without a new one.
- (void)noteSize:(CGSize)size NS_SWIFT_NAME(noteSize(_:));
@end

NS_ASSUME_NONNULL_END
