#import <Cocoa/Cocoa.h>
@class SCXPCClient;

@interface SCWeeklyScheduleViewController : NSViewController
- (instancetype)initWithClient:(SCXPCClient *)client;
@property (copy) void (^editBlocklist)(void);
- (void)refresh;
- (void)refreshSharedPolicyFromDaemonWithCompletion:(void (^)(NSError *error))completion;
- (void)syncSharedPolicyIfNeededWithCompletion:(void (^)(BOOL approved))completion;
@end
