//
//  SCDaemonBlockMethods.m
//  org.eyebeam.selfcontrold
//
//  Created by Charlie Stigler on 7/4/20.
//

#import "SCDaemonBlockMethods.h"
#import "SCSettings.h"
#import "SCWebsiteBreak.h"
#import "SCHelperToolUtilities.h"
#import "PacketFilter.h"
#import "BlockManager.h"
#import "SCDaemon.h"
#import "LaunchctlHelper.h"
#import "HostFileBlockerSet.h"

NSTimeInterval METHOD_LOCK_TIMEOUT = 5.0;
NSTimeInterval CHECKUP_LOCK_TIMEOUT = 0.5; // use a shorter lock timeout for checkups, because we'd prefer not to have tons pile up

@interface SCDaemonBlockMethods ()
+ (void)restoreWebsiteBreakWhileLocked;
+ (void)updateBlockEndDate:(NSDate *)end scheduled:(BOOL)scheduled reply:(void (^)(NSError *))reply;
@end

@implementation SCDaemonBlockMethods

+ (NSLock*)daemonMethodLock {
    static NSLock* lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply timeout:(NSTimeInterval)timeout {
    // only run one request at a time, so we avoid weird situations like trying to run a checkup while we're starting a block
    if (![self.daemonMethodLock lockBeforeDate: [NSDate dateWithTimeIntervalSinceNow: timeout]]) {
        // if we couldn't get a lock within 10 seconds, something is weird
        // but we probably shouldn't still run, because that's just unexpected at that point
        // don't capture this error on Sentry because it's very usual for checkups to timeout
        NSError* err = [SCErr errorWithCode: 300];
        NSLog(@"ERROR: Timed out acquiring request lock (after %f seconds)", timeout);

        if (reply != nil) {
            reply(err);
        }
        return NO;
    }
    return YES;
}
+ (BOOL)lockOrTimeout:(void(^)(NSError* error))reply {
    return [self lockOrTimeout: reply timeout: METHOD_LOCK_TIMEOUT];
}


+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    [self startBlockWithControllingUID:controllingUID blocklist:blocklist isAllowlist:isAllowlist endDate:endDate blockSettings:blockSettings scheduled:NO authorization:authData reply:reply];
}

+ (void)startBlockWithControllingUID:(uid_t)controllingUID blocklist:(NSArray<NSString*>*)blocklist isAllowlist:(BOOL)isAllowlist endDate:(NSDate*)endDate blockSettings:(NSDictionary*)blockSettings scheduled:(BOOL)scheduled authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    // we reset at the _end_ of every method, but we'll also reset at the _start_ here
    // because startBlock can sometimes take a while, and it'd be a shame if the daemon killed itself
    // before we were done
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    
    [SCSentry addBreadcrumb: @"Daemon method startBlock called" category: @"daemon"];
    
    if ([SCBlockUtilities anyBlockIsRunning]) {
        NSLog(@"ERROR: Can't start block since a block is already running");
        NSError* err = [SCErr errorWithCode: 301];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    // clear any legacy block information - no longer useful and could potentially confuse things
    // but first, copy it over one more time (this should've already happened once in the app, but you never know)
    if ([SCMigrationUtilities legacySettingsFoundForUser: controllingUID]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults: controllingUID];
        [SCMigrationUtilities clearLegacySettingsForUser: controllingUID];
        
        // if we had legacy settings, there's a small chance the old helper tool could still be around
        // make sure it's dead and gone
        [LaunchctlHelper unloadLaunchdJobWithPlistAt: @"/Library/LaunchDaemons/org.eyebeam.SelfControl.plist"];
    }

    SCSettings* settings = [SCSettings sharedSettings];
    [settings setValue:@(controllingUID) forKey:@"BlockControllingUID"];
    [settings setValue:@"" forKey:@"WebsiteBreakDomain"];
    [settings setValue:NSDate.distantPast forKey:@"WebsiteBreakUntil"];
    // The global cooldown survives new blocks and daemon restarts.
    // update SCSettings with the blocklist and end date that've been requested
    [settings setValue: blocklist forKey: @"ActiveBlocklist"];
    [settings setValue: @(isAllowlist) forKey: @"ActiveBlockAsWhitelist"];
    [settings setValue: endDate forKey: @"BlockEndDate"];
    [settings setValue:@YES forKey:@"ScheduleManagedBlock"];
    [settings setValue:scheduled ? NSDate.distantPast : endDate forKey:@"ManualBlockEndDate"];
    
    // update all the settings for the block, which we're basically just copying from defaults to settings
    [settings setValue: blockSettings[@"ClearCaches"] forKey: @"ClearCaches"];
    [settings setValue: blockSettings[@"AllowLocalNetworks"] forKey: @"AllowLocalNetworks"];
    [settings setValue: blockSettings[@"EvaluateCommonSubdomains"] forKey: @"EvaluateCommonSubdomains"];
    [settings setValue: blockSettings[@"IncludeLinkedDomains"] forKey: @"IncludeLinkedDomains"];
    [settings setValue: blockSettings[@"BlockSoundShouldPlay"] forKey: @"BlockSoundShouldPlay"];
    [settings setValue: blockSettings[@"BlockSound"] forKey: @"BlockSound"];
    [settings setValue: blockSettings[@"EnableErrorReporting"] forKey: @"EnableErrorReporting"];

    if(([blocklist count] <= 0 && !isAllowlist) || [SCBlockUtilities currentBlockIsExpired]) {
        NSLog(@"ERROR: Blocklist is empty, or block end date is in the past");
        NSLog(@"Block End Date: %@ (%@), vs now is %@", [settings valueForKey: @"BlockEndDate"], [[settings valueForKey: @"BlockEndDate"] class], [NSDate date]);
        NSError* err = [SCErr errorWithCode: 302];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }

    NSLog(@"Adding firewall rules...");
    [SCHelperToolUtilities installBlockRulesFromSettings];
    [settings setValue: @YES forKey: @"BlockIsRunning"];
    
    NSError* syncErr = [settings syncSettingsAndWait: 5]; // synchronize ASAP since BlockIsRunning is a really important one
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after starting block", syncErr);
        [SCSentry captureError: syncErr];
    }

    NSLog(@"Firewall rules added!");
    
    [SCHelperToolUtilities sendConfigurationChangedNotification];

    // Clear all caches if the user has the correct preference set, so
    // that blocked pages are not loaded from a cache.
    [SCHelperToolUtilities clearCachesIfRequested];

    [SCSentry addBreadcrumb: @"Daemon added block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully added.");
    reply(nil);

    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [[SCDaemon sharedDaemon] startCheckupTimer];
    [self.daemonMethodLock unlock];
}

+ (void)updateBlocklist:(NSArray<NSString *> *)newBlocklist authorization:(NSData *)authData reply:(void (^)(NSError *))reply {
    if (![self lockOrTimeout:reply]) return;
    NSError *error = [self appendBlocklistWhileLocked:newBlocklist];
    [self.daemonMethodLock unlock];
    reply(error);
}

+ (NSError *)appendBlocklistWhileLocked:(NSArray<NSString *> *)domains {
    if ([SCBlockUtilities legacyBlockIsRunning]) return [SCErr errorWithCode:303];
    if (![SCBlockUtilities modernBlockIsRunning]) return [SCErr errorWithCode:304];
    SCSettings *settings = SCSettings.sharedSettings;
    if ([settings boolForKey:@"ActiveBlockAsWhitelist"]) return [SCErr errorWithCode:305];
    NSArray *active = [settings valueForKey:@"ActiveBlocklist"] ?: @[];
    NSMutableOrderedSet *effective = [NSMutableOrderedSet orderedSetWithArray:active];
    [effective addObjectsFromArray:domains];
    NSMutableArray *added = [effective.array mutableCopy];
    [added removeObjectsInArray:active];
    if (!added.count) return [settings syncSettingsAndWait:5];
    BlockManager *manager = [[BlockManager alloc] initAsAllowlist:NO
        allowLocal:[settings boolForKey:@"AllowLocalNetworks"]
        includeCommonSubdomains:[settings boolForKey:@"EvaluateCommonSubdomains"]
        includeLinkedDomains:[settings boolForKey:@"IncludeLinkedDomains"]];
    if (![manager enterAppendMode]) return [NSError errorWithDomain:@"SelfControl.Browser" code:2
        userInfo:@{NSLocalizedDescriptionKey:@"The active network rules are unavailable. Open SelfControl to repair them."}];
    [manager addBlockEntriesFromStrings:SCWebsiteBreakFilteredList(added, [settings valueForKey:@"WebsiteBreakDomain"],
        [settings valueForKey:@"WebsiteBreakUntil"], NSDate.date, NO)];
    if (![manager finishAppending]) {
        return [NSError errorWithDomain:@"SelfControl.Browser" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Could not append the active network rules. Click again to retry."}];
    }
    [settings setValue:effective.array forKey:@"ActiveBlocklist"];
    NSError *error = [settings syncSettingsAndWait:5];
    [SCHelperToolUtilities sendConfigurationChangedNotification];
    [SCHelperToolUtilities clearCachesIfRequested];
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    return error;
}

+ (void)updateBlockEndDate:(NSDate*)newEndDate authorization:(NSData *)authData reply:(void(^)(NSError* error))reply {
    [self updateBlockEndDate:newEndDate scheduled:NO reply:reply];
}

+ (void)extendScheduledBlockTo:(NSDate *)end reply:(void (^)(NSError *))reply {
    [self updateBlockEndDate:end scheduled:YES reply:reply];
}

+ (void)updateBlockEndDate:(NSDate *)newEndDate scheduled:(BOOL)scheduled reply:(void (^)(NSError *))reply {
    if (![SCDaemonBlockMethods lockOrTimeout: reply]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method updateBlockEndDate called" category: @"daemon"];

    if ([SCBlockUtilities legacyBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date because a legacy block is running");
        NSError* err = [SCErr errorWithCode: 306];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if (![SCBlockUtilities modernBlockIsRunning]) {
        NSLog(@"ERROR: Can't update block end date since block isn't running");
        NSError* err = [SCErr errorWithCode: 307];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    SCSettings* settings = [SCSettings sharedSettings];
    
    // this can only be used to *extend* the block end date - not shorten it!
    // and we also won't let them extend by more than 24 hours at a time, for safety...
    // TODO: they should be able to extend up to MaxBlockLength minutes, right?
    NSDate* currentEndDate = [settings valueForKey: @"BlockEndDate"];
    if ([newEndDate timeIntervalSinceDate: currentEndDate] < 0) {
        NSLog(@"ERROR: Can't update block end date to an earlier date");
        NSError* err = [SCErr errorWithCode: 308];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    if ([newEndDate timeIntervalSinceDate: currentEndDate] > 86400) { // 86400 seconds = 1 day
        NSLog(@"ERROR: Can't extend block end date by more than 1 day at a time");
        NSError* err = [SCErr errorWithCode: 309];
        [SCSentry captureError: err];
        reply(err);
        [self.daemonMethodLock unlock];
        return;
    }
    
    [settings setValue: newEndDate forKey: @"BlockEndDate"];
    if (!scheduled) {
        [settings setValue:@YES forKey:@"ScheduleManagedBlock"];
        [settings setValue:newEndDate forKey:@"ManualBlockEndDate"];
    }
    
    // make sure everyone knows about our new end date
    NSError* syncErr = [settings syncSettingsAndWait: 5];
    if (syncErr != nil) {
        NSLog(@"WARNING: Sync failed or timed out with error %@ after extending block", syncErr);
        [SCSentry captureError: syncErr];
    }

    [SCHelperToolUtilities sendConfigurationChangedNotification];

    [SCSentry addBreadcrumb: @"Daemon extended block successfully" category: @"daemon"];
    NSLog(@"INFO: Block successfully extended.");
    reply(nil);
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
}

+ (NSError *)applyApprovedPolicyWhileLocked:(NSDictionary *)policy endDate:(NSDate *)end {
    if (![SCBlockUtilities anyBlockIsRunning]) return nil;
    if ([SCBlockUtilities legacyBlockIsRunning])
        return [NSError errorWithDomain:@"SelfControl.Schedule" code:3 userInfo:@{NSLocalizedDescriptionKey:@"This block was started by an older SelfControl version. Its rules cannot be edited until it ends."}];
    SCSettings *settings = SCSettings.sharedSettings;
    NSMutableDictionary *before = [NSMutableDictionary new];
    NSArray *keys = [@[@"ActiveBlocklist", @"ActiveBlockAsWhitelist", @"BlockEndDate", @"BlockIsRunning", @"ScheduleManagedBlock", @"ManualBlockEndDate"] arrayByAddingObjectsFromArray:[policy[@"blockSettings"] allKeys]];
    for (NSString *key in keys) before[key] = [settings valueForKey:key];
    BOOL keepRunning = end.timeIntervalSinceNow > 0 && ([policy[@"isAllowlist"] boolValue] || [policy[@"blocklist"] count] > 0);
    BOOL rebuild = ![before[@"ActiveBlocklist"] isEqual:policy[@"blocklist"]] ||
        [before[@"ActiveBlockAsWhitelist"] boolValue] != [policy[@"isAllowlist"] boolValue];
    for (NSString *key in @[@"AllowLocalNetworks", @"EvaluateCommonSubdomains", @"IncludeLinkedDomains"])
        rebuild |= ![before[key] isEqual:policy[@"blockSettings"][key]];
    if (!keepRunning || rebuild) {
        if (![[BlockManager new] clearBlock]) {
            [SCHelperToolUtilities installBlockRulesFromSettings];
            return [NSError errorWithDomain:@"SelfControl.Schedule" code:4 userInfo:@{NSLocalizedDescriptionKey:@"Could not replace the active firewall rules. The previous block was restored."}];
        }
    }
    if (keepRunning) {
        [settings setValue:policy[@"blocklist"] forKey:@"ActiveBlocklist"];
        [settings setValue:policy[@"isAllowlist"] forKey:@"ActiveBlockAsWhitelist"];
        [settings setValue:end forKey:@"BlockEndDate"];
        [policy[@"blockSettings"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) { [settings setValue:value forKey:key]; }];
    } else {
        [SCBlockUtilities removeBlockFromSettings];
        [settings setValue:@NO forKey:@"ScheduleManagedBlock"];
        [settings setValue:NSDate.distantPast forKey:@"ManualBlockEndDate"];
    }
    NSError *error = [settings syncSettingsAndWait:5];
    if (!error && keepRunning && rebuild) {
        [SCHelperToolUtilities installBlockRulesFromSettings];
        if (![[BlockManager new] blockIsActive]) error = [NSError errorWithDomain:@"SelfControl.Schedule" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Could not install the revised firewall rules."}];
    }
    if (error) {
        if (rebuild || !keepRunning) [[BlockManager new] clearBlock];
        [before enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) { [settings setValue:value forKey:key]; }];
        [settings syncSettingsAndWait:5];
        if (rebuild || !keepRunning) [SCHelperToolUtilities installBlockRulesFromSettings];
        [SCHelperToolUtilities sendConfigurationChangedNotification];
        return error;
    }
    if (!keepRunning) [[SCDaemon sharedDaemon] stopCheckupTimer];
    if (rebuild || !keepRunning) [SCHelperToolUtilities clearOSDNSCache];
    [SCHelperToolUtilities sendConfigurationChangedNotification];
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    return nil;
}

// All callers hold daemonMethodLock. Keep the pending marker until rules are restored,
// so a failed restore is retried by the next checkup, including after daemon restart.
+ (void)restoreWebsiteBreakWhileLocked {
    SCSettings *settings = SCSettings.sharedSettings;
    [settings setValue:NSDate.distantPast forKey:@"WebsiteBreakUntil"];
    [settings syncSettingsAndWait:5];
    if (![[BlockManager new] clearBlock]) {
        [SCHelperToolUtilities installBlockRulesFromSettings];
        return;
    }
    [SCHelperToolUtilities installBlockRulesFromSettings];
    if (![[BlockManager new] blockIsActive]) return;
    [settings setValue:@"" forKey:@"WebsiteBreakDomain"];
    [settings syncSettingsAndWait:5];
    [SCHelperToolUtilities clearOSDNSCache];
    [SCHelperToolUtilities sendConfigurationChangedNotification];
}

+ (void)requestWebsiteBreak:(NSString *)requested controllingUID:(uid_t)uid reply:(void (^)(NSError *))reply {
    if (![self lockOrTimeout:reply]) return;
    SCSettings *settings = SCSettings.sharedSettings;
    NSString *domain = SCWebsiteBreakDomain(requested);
    NSString *message = nil;
    NSDate *now = NSDate.date;
    NSArray *sites = [settings valueForKey:@"ActiveBlocklist"];
    if (!uid || uid != [[settings valueForKey:@"BlockControllingUID"] unsignedIntValue])
        message = @"This block belongs to another Mac user. Older blocks must finish before website breaks are available.";
    else if (![SCBlockUtilities modernBlockIsRunning] || [SCBlockUtilities currentBlockIsExpired] || [settings boolForKey:@"ActiveBlockAsWhitelist"])
        message = @"Website breaks require an active website blocklist.";
    else if ([[settings valueForKey:@"WebsiteBreakNextAvailable"] compare:now] == NSOrderedDescending)
        message = @"A website break is available once every 30 minutes. Wait until the cooldown ends.";
    else if (!domain || [sites indexOfObjectPassingTest:^BOOL(NSString *site, NSUInteger index, BOOL *stop) {
        return [SCWebsiteBreakDomain(site) isEqualToString:domain];
    }] == NSNotFound)
        message = @"Choose a website from the active blocklist. IP addresses and port-specific rules do not support breaks.";
    NSError *error;
    if (message) error = [NSError errorWithDomain:@"SelfControl.WebsiteBreak" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    if (!error) {
        // Persist the cooldown before changing network rules. Repeated/concurrent requests
        // and app restarts cannot extend the break or reset its allowance.
        [settings setValue:domain forKey:@"WebsiteBreakDomain"];
        [settings setValue:[now dateByAddingTimeInterval:120] forKey:@"WebsiteBreakUntil"];
        [settings setValue:[now dateByAddingTimeInterval:1800] forKey:@"WebsiteBreakNextAvailable"];
        error = [settings syncSettingsAndWait:5];
        if (!error && ![[BlockManager new] clearBlock])
            error = [NSError errorWithDomain:@"SelfControl.WebsiteBreak" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Could not update the network rules. Please try again later."}];
        if (!error) {
            [SCHelperToolUtilities installBlockRulesFromSettings];
            if (![[BlockManager new] blockIsActive])
                error = [NSError errorWithDomain:@"SelfControl.WebsiteBreak" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Could not install the temporary network rules."}];
        }
        if (error) [self restoreWebsiteBreakWhileLocked];
        [SCHelperToolUtilities clearOSDNSCache];
        [SCHelperToolUtilities sendConfigurationChangedNotification];
    }
    [self.daemonMethodLock unlock];
    reply(error);
}

+ (void)checkupBlock {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkupBlock called" category: @"daemon"];

    NSTimeInterval integrityCheckIntervalSecs = 15.0;
    static NSDate* lastBlockIntegrityCheck;
    if (lastBlockIntegrityCheck == nil) {
        lastBlockIntegrityCheck = [NSDate distantPast];
    }

    BOOL shouldRunIntegrityCheck = NO;
    if(![SCBlockUtilities anyBlockIsRunning]) {
        // No block appears to be running at all in our settings.
        // Most likely, the user removed it trying to get around the block. Boo!
        // but for safety and to avoid permablocks (we no longer know when the block should end)
        // we should clear the block now.
        // but let them know that we noticed their (likely) cheating and we're not happy!
        NSLog(@"INFO: Checkup ran, no active block found.");
        
        [SCSentry captureMessage: @"Checkup ran and no active block found! Removing block, tampering suspected..."];
        
        [SCHelperToolUtilities removeBlock];

        [SCHelperToolUtilities sendConfigurationChangedNotification];
        
        // Temporarily disabled the TamperingDetection flag because it was sometimes causing false positives
        // (i.e. people having the background set repeatedly despite no attempts to cheat)
        // We will try to bring this feature back once we can debug it
        // GitHub issue: https://github.com/SelfControlApp/selfcontrol/issues/621
        // [settings setValue: @YES forKey: @"TamperingDetected"];
        //        [settings synchronizeSettings];
        //
        
        // once the checkups stop, the daemon will clear itself in a while due to inactivity
        [[SCDaemon sharedDaemon] stopCheckupTimer];
    } else if ([SCBlockUtilities currentBlockIsExpired]) {
        NSLog(@"INFO: Checkup ran, block expired, removing block.");
        
        [SCHelperToolUtilities removeBlock];

        [SCHelperToolUtilities sendConfigurationChangedNotification];

        [SCSentry addBreadcrumb: @"Daemon found and cleared expired block" category: @"daemon"];

        // once the checkups stop, the daemon will clear itself in a while due to inactivity
        [[SCDaemon sharedDaemon] stopCheckupTimer];
    } else if ([[SCSettings.sharedSettings valueForKey:@"WebsiteBreakDomain"] length] &&
        [[SCSettings.sharedSettings valueForKey:@"WebsiteBreakUntil"] timeIntervalSinceNow] <= 0) {
        [self restoreWebsiteBreakWhileLocked];
    } else if ([[NSDate date] timeIntervalSinceDate: lastBlockIntegrityCheck] > integrityCheckIntervalSecs) {
        lastBlockIntegrityCheck = [NSDate date];
        // The block is still on.  Every once in a while, we should
        // check if anybody removed our rules, and if so
        // re-add them.
        shouldRunIntegrityCheck = YES;
    }
    
    [[SCDaemon sharedDaemon] resetInactivityTimer];
    [self.daemonMethodLock unlock];
    
    // if we need to run an integrity check, we need to do it at the very end after we give up our lock
    // because checkBlockIntegrity requests its own lock, and we don't want it to deadlock
    if (shouldRunIntegrityCheck) {
        [SCDaemonBlockMethods checkBlockIntegrity];
    }
}

+ (void)checkBlockIntegrity {
    if (![SCDaemonBlockMethods lockOrTimeout: nil timeout: CHECKUP_LOCK_TIMEOUT]) {
        return;
    }
    
    [SCSentry addBreadcrumb: @"Daemon method checkBlockIntegrity called" category: @"daemon"];

    SCSettings* settings = [SCSettings sharedSettings];
    PacketFilter* pf = [[PacketFilter alloc] init];
    HostFileBlockerSet* hostFileBlockerSet = [[HostFileBlockerSet alloc] init];
    if(![pf containsSelfControlBlock] || (![settings boolForKey: @"ActiveBlockAsWhitelist"] && ![hostFileBlockerSet.defaultBlocker containsSelfControlBlock])) {
        NSLog(@"INFO: Block is missing in PF or hosts, re-adding...");
        // The firewall is missing at least the block header.  Let's clear everything
        // before we re-add to make sure everything goes smoothly.

        [pf stopBlock: false];

        [hostFileBlockerSet removeSelfControlBlock];
        BOOL success = [hostFileBlockerSet writeNewFileContents];
        // Revert the host file blocker's file contents to disk so we can check
        // whether or not it still contains the block after our write (aka we messed up).
        [hostFileBlockerSet revertFileContentsToDisk];
        if(!success || [hostFileBlockerSet.defaultBlocker containsSelfControlBlock]) {
            NSLog(@"WARNING: Error removing host file block.  Attempting to restore backup.");

            if([hostFileBlockerSet restoreBackupHostsFile])
                NSLog(@"INFO: Host file backup restored.");
            else
                NSLog(@"ERROR: Host file backup could not be restored.  This may result in a permanent block.");
        }

        // Get rid of the backup file since we're about to make a new one.
        [hostFileBlockerSet deleteBackupHostsFile];

        // Perform the re-add of the rules
        [SCHelperToolUtilities installBlockRulesFromSettings];
        
        [SCHelperToolUtilities clearCachesIfRequested];

        [SCSentry addBreadcrumb: @"Daemon found compromised block integrity and re-added rules" category: @"daemon"];
        NSLog(@"INFO: Integrity check ran; readded block rules.");
    } else NSLog(@"INFO: Integrity check ran; no action needed.");
    
    [self.daemonMethodLock unlock];
}

@end
