#import "SCStatusItemState.h"

@implementation SCStatusItemState
- (instancetype)initWithBlockPhase:(SCStatusItemBlockPhase)blockPhase
                       breakPhase:(SCStatusItemBreakPhase)breakPhase
                     blockEndDate:(NSDate *)blockEndDate
              breakTransitionDate:(NSDate *)breakTransitionDate
                        allowlist:(BOOL)allowlist busy:(BOOL)busy {
    if ((self = [super init])) {
        _blockPhase = blockPhase;
        _breakPhase = blockPhase == SCStatusItemBlockModern && !allowlist ? breakPhase : SCStatusItemBreakUnavailable;
        _blockEndDate = blockPhase == SCStatusItemBlockIdle ? nil : [blockEndDate copy];
        _breakTransitionDate = (_breakPhase == SCStatusItemBreakActive || _breakPhase == SCStatusItemBreakCooldown) ? [breakTransitionDate copy] : nil;
        _allowlist = allowlist;
        _busy = busy;
    }
    return self;
}
@end
