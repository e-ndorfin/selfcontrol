#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SCStatusItemBlockPhase) {
    SCStatusItemBlockIdle, SCStatusItemBlockModern, SCStatusItemBlockLegacy, SCStatusItemBlockFinishing
};
typedef NS_ENUM(NSInteger, SCStatusItemBreakPhase) {
    SCStatusItemBreakUnavailable, SCStatusItemBreakReady, SCStatusItemBreakPending,
    SCStatusItemBreakActive, SCStatusItemBreakCooldown
};
@interface SCStatusItemState : NSObject
@property (nonatomic, readonly) SCStatusItemBlockPhase blockPhase;
@property (nonatomic, readonly) SCStatusItemBreakPhase breakPhase;
@property (nonatomic, readonly, copy) NSDate *blockEndDate;
@property (nonatomic, readonly, copy) NSDate *breakTransitionDate;
@property (nonatomic, readonly) BOOL allowlist;
@property (nonatomic, readonly) BOOL busy;
- (instancetype)initWithBlockPhase:(SCStatusItemBlockPhase)blockPhase
                       breakPhase:(SCStatusItemBreakPhase)breakPhase
                     blockEndDate:(NSDate *)blockEndDate
              breakTransitionDate:(NSDate *)breakTransitionDate
                        allowlist:(BOOL)allowlist busy:(BOOL)busy;
@end
