#import <Foundation/Foundation.h>

@interface SCScheduleService : NSObject
@property (atomic, readonly) BOOL enabled;
@property (atomic, readonly) BOOL friendProtectionEnabled;
+ (instancetype)sharedService;
- (void)start;
- (void)getStatus:(void (^)(NSDictionary *status))reply;
- (void)setConfiguration:(NSDictionary *)configuration controllingUID:(uid_t)uid reply:(void (^)(NSError *error))reply;
- (void)setConfiguration:(NSDictionary *)configuration controllingUID:(uid_t)uid friendPassword:(NSString *)password reply:(void (^)(NSError *error))reply;
- (void)setSharedPolicy:(NSDictionary *)policy controllingUID:(uid_t)uid friendPassword:(NSString *)password reply:(void (^)(NSError *error))reply;
- (void)setFriendPassword:(NSString *)password policy:(NSDictionary *)policy controllingUID:(uid_t)uid reply:(void (^)(NSError *error))reply;
- (void)disableFriendPassword:(NSString *)password reply:(void (^)(NSError *error))reply;
- (void)startManualBlockWithControllingUID:(uid_t)uid blocklist:(NSArray *)sites isAllowlist:(BOOL)isAllowlist endDate:(NSDate *)endDate blockSettings:(NSDictionary *)settings authorization:(NSData *)authorization reply:(void (^)(NSError *error))reply;
- (void)requestWebsiteBreak:(NSString *)domain controllingUID:(uid_t)uid reply:(void (^)(NSError *error))reply;
- (void)appendBlockedWebsites:(NSArray<NSString *> *)domains controllingUID:(uid_t)uid reply:(void (^)(NSDictionary *result, NSError *error))reply;
- (void)prepareBrowserIntegration:(NSDictionary *)policy controllingUID:(uid_t)uid reply:(void (^)(NSError *error))reply;
- (void)appendBlocklist:(NSArray<NSString *> *)entries reply:(void (^)(NSError *error))reply;
@end
