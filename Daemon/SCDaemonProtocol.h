//
//  SCDaemonProtocol.h
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol SCDaemonProtocol <NSObject>

- (void)getWeeklyScheduleWithReply:(void (^)(NSDictionary *status))reply;
- (void)setWeeklySchedule:(NSDictionary *)configuration authorization:(NSData *)authData reply:(void (^)(NSError *error))reply;
- (void)setWeeklySchedule:(NSDictionary *)configuration friendPassword:(NSString *)password authorization:(NSData *)authData reply:(void (^)(NSError *error))reply;
- (void)setSharedPolicy:(NSDictionary *)policy friendPassword:(NSString *)password authorization:(NSData *)authData reply:(void (^)(NSError *error))reply;
- (void)setFriendPassword:(NSString *)password policy:(NSDictionary *)policy authorization:(NSData *)authData reply:(void (^)(NSError *error))reply;
- (void)disableFriendPassword:(NSString *)password authorization:(NSData *)authData reply:(void (^)(NSError *error))reply;
- (void)appendWeeklyWebsites:(NSArray<NSString *> *)entries authorization:(NSData *)authData reply:(void (^)(NSError *error))reply;

- (void)requestWebsiteBreak:(NSString *)domain reply:(void (^)(NSError * _Nullable error))reply;

- (void)appendBlockedWebsites:(NSArray<NSString *> *)domains reply:(void (^)(NSDictionary *result, NSError * _Nullable error))reply;
- (void)prepareBrowserIntegration:(NSDictionary *)policy authorization:(NSData *)authorization reply:(void (^)(NSError * _Nullable error))reply;

// XPC method to start block
- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to add to blocklist
- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to extend block
- (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// XPC method to get version of the installed daemon
- (void)getVersionWithReply:(void(^)(NSString * version))reply;

@end

NS_ASSUME_NONNULL_END
