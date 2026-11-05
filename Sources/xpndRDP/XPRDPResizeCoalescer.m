#import "XPRDPResizeCoalescer.h"

@implementation XPRDPResizeCoalescer {
    NSTimeInterval _idle;
    void (^_handler)(CGSize);
    NSUInteger _generation;  // guarded by @synchronized(self)
    CGSize _size;
}

- (instancetype)initWithIdleInterval:(NSTimeInterval)seconds handler:(void (^)(CGSize))handler {
    if ((self = [super init])) {
        _idle = seconds;
        _handler = [handler copy];
    }
    return self;
}

- (void)noteSize:(CGSize)size {
    NSUInteger generation;
    @synchronized(self) {
        generation = ++_generation;
        _size = size;
    }
    __weak XPRDPResizeCoalescer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_idle * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XPRDPResizeCoalescer *s = weakSelf;
        if (!s) return;
        CGSize last;
        @synchronized(s) {
            if (s->_generation != generation) return;  // a newer size restarted the wait
            last = s->_size;
        }
        s->_handler(last);
    });
}

@end
