//
//  SCDaemonBlockMethods.h
//  org.eyebeam.selfcontrold
//
//  Created by Charlie Stigler on 7/4/20.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Top-level logic for different methods run by the SelfControl daemon
// these logics can be run by XPC methods, or elsewhere
@interface SCDaemonBlockMethods : NSObject

@property (class, readonly) NSLock* daemonMethodLock;

+ (void)requestWebsiteBreak:(NSString *)domain controllingUID:(uid_t)uid reply:(void (^)(NSError * _Nullable error))reply;

// Starts a block
+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// Internal schedule entry points; these are not exposed over XPC.
+ (void)startBlockWithControllingUID:(uid_t)uid blocklist:(NSArray<NSString *> *)sites isAllowlist:(BOOL)allowlist endDate:(NSDate *)end blockSettings:(NSDictionary *)settings scheduled:(BOOL)scheduled authorization:(NSData *)authorization reply:(void (^)(NSError *error))reply;
+ (void)extendScheduledBlockTo:(NSDate *)end reply:(void (^)(NSError *error))reply;
// Caller must hold daemonMethodLock and have approved the exact policy and end date.
+ (nullable NSError *)applyApprovedPolicyWhileLocked:(NSDictionary *)policy endDate:(NSDate *)end;

// Caller must hold daemonMethodLock. This never removes existing restrictions.
+ (nullable NSError *)appendBlocklistWhileLocked:(NSArray<NSString *> *)domains;

// Checks whether the block is expired or compromised, and takes action to fix
+ (void)checkupBlock;

// updates the blocklist for the currently running block
// (i.e. adds new sites to the list)
+ (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

// updates the block end date for the currently running block
// (i.e. extends the block)
+ (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply;

+ (void)checkBlockIntegrity;

@end

NS_ASSUME_NONNULL_END
