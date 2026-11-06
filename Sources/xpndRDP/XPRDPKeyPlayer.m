#import "XPRDPKeyPlayer.h"

@implementation XPRDPKeyStep

- (instancetype)initWithKind:(XPRDPKeyStepKind)kind {
    if ((self = [super init])) {
        _kind = kind;
        _text = @"";
    }
    return self;
}

- (instancetype)initWithScancode:(uint16_t)scancode down:(BOOL)down {
    if ((self = [self initWithKind:XPRDPKeyStepKindScancode])) {
        _scancode = scancode;
        _down = down;
    }
    return self;
}

- (instancetype)initWithText:(NSString *)text {
    if ((self = [self initWithKind:XPRDPKeyStepKindText]))
        _text = [text copy];
    return self;
}

- (instancetype)initWithMilliseconds:(NSInteger)milliseconds {
    if ((self = [self initWithKind:XPRDPKeyStepKindPause]))
        _milliseconds = milliseconds;
    return self;
}

@end

@implementation XPRDPKeyPlayer {
    void (^_sendScancode)(uint16_t, BOOL);
    void (^_sendText)(NSString *);
    BOOL (^_canSend)(void);
    NSMutableArray<XPRDPKeyStep *> *_steps;
    NSMutableArray<NSNumber *> *_held;
    NSUInteger _pause;  // the pause being waited out; bumped to abandon it
    BOOL _pausing;
}

- (instancetype)initWithScancode:(void (^)(uint16_t, BOOL))sendScancode text:(void (^)(NSString *))sendText
                         canSend:(BOOL (^)(void))canSend {
    if ((self = [super init])) {
        _sendScancode = [sendScancode copy];
        _sendText = [sendText copy];
        _canSend = [canSend copy];
        _steps = [NSMutableArray array];
        _held = [NSMutableArray array];
    }
    return self;
}

- (void)play:(NSArray<XPRDPKeyStep *> *)steps {
    [_steps addObjectsFromArray:steps];
    if (!_pausing)
        [self advance];
}

- (void)cancel {
    _pause++;
    _pausing = NO;
    [_steps removeAllObjects];
    [self releaseHeld];
}

- (void)advance {
    while (_steps.count) {
        if (!_canSend()) {
            [self cancel];
            return;
        }
        XPRDPKeyStep *step = _steps.firstObject;
        [_steps removeObjectAtIndex:0];
        switch (step.kind) {
            case XPRDPKeyStepKindScancode:
                _sendScancode(step.scancode, step.down);
                if (step.down)
                    [_held addObject:@(step.scancode)];
                else
                    [_held removeObject:@(step.scancode)];
                break;
            case XPRDPKeyStepKindText:
                _sendText(step.text);
                break;
            case XPRDPKeyStepKindPause:
                [self waitMilliseconds:step.milliseconds];
                return;
        }
    }
    [self releaseHeld];
}

- (void)waitMilliseconds:(NSInteger)milliseconds {
    _pausing = YES;
    const NSUInteger pause = ++_pause;
    __weak XPRDPKeyPlayer *weakSelf = self;
    // The main queue, not an NSTimer: it also runs while a menu or a drag tracks the mouse.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, milliseconds * (int64_t)NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        XPRDPKeyPlayer *player = weakSelf;
        if (!player || player->_pause != pause)
            return;
        player->_pausing = NO;
        [player advance];
    });
}

/// Last down, first up. With no connection left there is nothing to release them on.
- (void)releaseHeld {
    if (_canSend())
        for (NSNumber *scancode in _held.reverseObjectEnumerator)
            _sendScancode(scancode.unsignedShortValue, NO);
    [_held removeAllObjects];
}

@end
