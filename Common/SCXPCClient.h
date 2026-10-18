//
//  SCAppXPC.h
//  SelfControl
//
//  Created by Charlie Stigler on 7/4/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCXPCClient : NSObject

@property (readonly, getter=isConnected) BOOL connected;

- (void)connectToHelperTool;
- (void)installDaemon:(void(^)(NSError*))callback;
- (void)refreshConnectionAndRun:(void(^)(void))callback;
- (void)connectAndExecuteCommandBlock:(void(^)(NSError *))commandBlock;

- (void)getVersion:(void(^)(NSString* version, NSError* error))reply;
- (void)getWeeklySchedule:(void (^)(NSDictionary *status, NSError *error))reply;
- (void)setWeeklySchedule:(NSDictionary *)configuration reply:(void (^)(NSError *error))reply;
- (void)setWeeklySchedule:(NSDictionary *)configuration friendPassword:(NSString *)password reply:(void (^)(NSError *error))reply;
- (void)setSharedPolicy:(NSDictionary *)policy friendPassword:(NSString *)password reply:(void (^)(NSError *error))reply;
- (void)setFriendPassword:(NSString *)password policy:(NSDictionary *)policy reply:(void (^)(NSError *error))reply;
- (void)disableFriendPassword:(NSString *)password reply:(void (^)(NSError *error))reply;
- (void)appendWeeklyWebsites:(NSArray<NSString *> *)entries reply:(void (^)(NSError *error))reply;
- (void)requestWebsiteBreak:(NSString *)domain reply:(void (^)(NSError * _Nullable error))reply;

- (void)appendBlockedWebsites:(NSArray<NSString *> *)domains reply:(void (^)(NSDictionary *result, NSError * _Nullable error))reply;
- (void)prepareBrowserIntegration:(NSDictionary *)policy reply:(void (^)(NSError * _Nullable error))reply;
- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings reply:(void(^)(NSError* error))reply;
- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist reply:(void(^)(NSError* error))reply;
- (void)updateBlockEndDate:(NSDate*)newEndDate reply:(void(^)(NSError* error))reply;

@end

NS_ASSUME_NONNULL_END
