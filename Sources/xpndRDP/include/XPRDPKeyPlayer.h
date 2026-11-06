#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, XPRDPKeyStepKind) {
    XPRDPKeyStepKindScancode,
    XPRDPKeyStepKindText,
    XPRDPKeyStepKindPause,
};

/// One step of a key sequence.
@interface XPRDPKeyStep : NSObject
@property (readonly) XPRDPKeyStepKind kind;
/// FreeRDP's RDP_SCANCODE_* encoding: the extended flag is KBDEXT (0x0100).
@property (readonly) uint16_t scancode;
@property (readonly) BOOL down;
@property (readonly, copy) NSString *text;
@property (readonly) NSInteger milliseconds;
- (instancetype)initWithScancode:(uint16_t)scancode down:(BOOL)down;
- (instancetype)initWithText:(NSString *)text;
- (instancetype)initWithMilliseconds:(NSInteger)milliseconds;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Plays key sequences in order, waiting out pauses without blocking. Main thread only.
/// `canSend` is asked before every step, so a session that ended during a pause gets nothing more.
@interface XPRDPKeyPlayer : NSObject
- (instancetype)initWithScancode:(void (^)(uint16_t scancode, BOOL down))sendScancode
                            text:(void (^)(NSString *text))sendText
                         canSend:(BOOL (^)(void))canSend NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// Runs now, or after the sequence already waiting on a pause. Keys still held at the end are released.
- (void)play:(NSArray<XPRDPKeyStep *> *)steps;
/// Drops what is left, releasing held keys while `canSend` still says so.
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
