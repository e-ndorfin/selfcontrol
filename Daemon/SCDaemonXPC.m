//
//  SCDaemonXPC.m
//  selfcontrold
//
//  Created by Charlie Stigler on 5/30/20.
//

#import "SCDaemonXPC.h"
#import "SCDaemonBlockMethods.h"
#import "SCXPCAuthorization.h"
#import "SCScheduleService.h"

@implementation SCDaemonXPC

- (void)getWeeklyScheduleWithReply:(void (^)(NSDictionary *))reply {
    [[SCScheduleService sharedService] getStatus:reply];
}
- (void)setWeeklySchedule:(NSDictionary *)configuration authorization:(NSData *)authData reply:(void (^)(NSError *))reply {
    NSError *error = [SCXPCAuthorization checkAuthorization:authData command:_cmd];
    if (error) { reply(error); return; }
    [[SCScheduleService sharedService] setConfiguration:configuration controllingUID:self.requestingUID reply:reply];
}
- (void)appendWeeklyWebsites:(NSArray<NSString *> *)entries authorization:(NSData *)authData reply:(void (^)(NSError *))reply {
    NSError *error = [SCXPCAuthorization checkAuthorization:authData command:_cmd];
    if (error) { reply(error); return; }
    // This command only adds restrictions; the original active-block rules still apply.
    NSArray *clean = [SCMiscUtilities cleanBlocklist:entries];
    void (^persist)(NSError *) = ^(NSError *blockError) {
        if (blockError) { reply(blockError); return; }
        [[SCScheduleService sharedService] appendBlocklist:clean reply:reply];
    };
    if ([SCBlockUtilities anyBlockIsRunning]) {
        NSMutableOrderedSet *sites = [NSMutableOrderedSet orderedSetWithArray:[SCSettings.sharedSettings valueForKey:@"ActiveBlocklist"] ?: @[]];
        [sites addObjectsFromArray:clean];
        [SCDaemonBlockMethods updateBlocklist:sites.array authorization:authData reply:persist];
    } else {
        persist(nil);
    }
}

- (void)requestWebsiteBreak:(NSString *)domain reply:(void (^)(NSError *))reply {
    // Signed clients only; ownership, timing and scope are enforced in the daemon.
    // This bounded exception intentionally does not require the supervisor password.
    [[SCScheduleService sharedService] requestWebsiteBreak:domain controllingUID:self.requestingUID reply:reply];
}

- (void)appendBlockedWebsites:(NSArray<NSString *> *)domains reply:(void (^)(NSDictionary *, NSError *))reply {
    // The listener already authenticates the signed client. This narrow operation
    // accepts additions only, and the service verifies ownership and blocklist mode.
    [[SCScheduleService sharedService] appendBlockedWebsites:domains controllingUID:self.requestingUID reply:reply];
}
- (void)prepareBrowserIntegration:(NSDictionary *)policy authorization:(NSData *)authData reply:(void (^)(NSError *))reply {
    NSError *error = [SCXPCAuthorization checkAuthorization:authData command:_cmd];
    if (error) { reply(error); return; }
    [[SCScheduleService sharedService] prepareBrowserIntegration:policy controllingUID:self.requestingUID reply:reply];
}

- (void)setWeeklySchedule:(NSDictionary *)configuration friendPassword:(NSString *)password authorization:(NSData *)authData reply:(void (^)(NSError *))reply {
    NSError *error = [SCXPCAuthorization checkAuthorization:authData command:_cmd];
    if (error) { reply(error); return; }
    [[SCScheduleService sharedService] setConfiguration:configuration controllingUID:self.requestingUID friendPassword:password reply:reply];
}
- (void)setSharedPolicy:(NSDictionary *)policy friendPassword:(NSString *)password authorization:(NSData *)authData reply:(void (^)(NSError *))reply {
    NSError *error = [SCXPCAuthorization checkAuthorization:authData command:_cmd];
    if (error) { reply(error); return; }
    [[SCScheduleService sharedService] setSharedPolicy:policy controllingUID:self.requestingUID friendPassword:password reply:reply];
}
- (void)setFriendPassword:(NSString *)password policy:(NSDictionary *)policy authorization:(NSData *)authData reply:(void (^)(NSError *))reply {
    NSError *error = [SCXPCAuthorization checkAuthorization:authData command:_cmd];
    if (error) { reply(error); return; }
    [[SCScheduleService sharedService] setFriendPassword:password policy:policy controllingUID:self.requestingUID reply:reply];
}
- (void)disableFriendPassword:(NSString *)password authorization:(NSData *)authData reply:(void (^)(NSError *))reply {
    NSError *error = [SCXPCAuthorization checkAuthorization:authData command:_cmd];
    if (error) { reply(error); return; }
    [[SCScheduleService sharedService] disableFriendPassword:password reply:reply];
}

- (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: startBlockWithControllingUID");
    
    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: _cmd];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            NSLog(@"ERROR: XPC authorization failed due to error %@", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"AUTHORIZATION ACCEPTED for startBlock with authData %@ and command %s", authData, sel_getName(_cmd));
    }

    // The GUI and CLI both use the protected policy; a Mac admin authorization cannot bypass it.
    [[SCScheduleService sharedService] startManualBlockWithControllingUID:self.requestingUID blocklist:blocklist isAllowlist:isAllowlist endDate:endDate blockSettings:blockSettings authorization:authData reply:reply];
}

- (void)updateBlocklist:(NSArray<NSString*>*)newBlocklist authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: updateBlocklist");
    
    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: _cmd];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            NSLog(@"ERROR: XPC authorization failed due to error %@", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"AUTHORIZATION ACCEPTED for updateBlocklist with authData %@ and command %s", authData, sel_getName(_cmd));
    }
    
    [SCDaemonBlockMethods updateBlocklist: newBlocklist authorization: authData reply:^(NSError *blockError) {
        if (blockError) { reply(blockError); return; }
        // Add-to-block from the existing timer also updates future weekly blocks.
        [[SCScheduleService sharedService] appendBlocklist:newBlocklist reply:reply];
    }];
}

- (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    NSLog(@"XPC method called: updateBlockEndDate");
    
    NSError* error = [SCXPCAuthorization checkAuthorization: authData command: _cmd];
    if (error != nil) {
        if (![SCMiscUtilities errorIsAuthCanceled: error]) {
            NSLog(@"ERROR: XPC authorization failed due to error %@", error);
            [SCSentry captureError: error];
        }
        reply(error);
        return;
    } else {
        NSLog(@"AUTHORIZATION ACCEPTED for updateBlockENdDate with authData %@ and command %s", authData, sel_getName(_cmd));
    }
    
    [SCDaemonBlockMethods updateBlockEndDate: newEndDate authorization: authData reply: reply];
}

// Part of the HelperToolProtocol.  Returns the version number of the tool.  Note that never
// requires authorization.
- (void)getVersionWithReply:(void(^)(NSString * version))reply {
    NSLog(@"XPC method called: getVersionWithReply");
    // We specifically don't check for authorization here.  Everyone is always allowed to get
    // the version of the helper tool.
    reply(SELFCONTROL_VERSION_STRING);
}

@end
