#import "SCScheduleService.h"
#import "SCWeeklySchedule.h"
#import "SCFriendProtection.h"
#import "SCDaemonBlockMethods.h"
#import "SCDaemon.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>

static NSString * const SCScheduleDirectory = @"/Library/Application Support/SelfControl";

@interface SCScheduleService ()
@property (atomic, copy) NSDictionary *configuration;
@property (atomic, copy) NSString *lastError;
@property dispatch_queue_t queue;
@property NSTimer *timer;
@property (atomic) BOOL tickPending;
@property (atomic) BOOL protectionUnavailable;
@property NSUInteger failedPasswordAttempts;
@property NSDate *passwordRetryAfter;
@end

@implementation SCScheduleService
+ (instancetype)sharedService {
    static SCScheduleService *service;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ service = [self new]; });
    return service;
}
- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("org.eyebeam.selfcontrol.schedule", DISPATCH_QUEUE_SERIAL);
    return self;
}
- (NSString *)storageDirectory { return SCScheduleDirectory; }
- (NSString *)storagePath { return [self.storageDirectory stringByAppendingPathComponent:@"WeeklySchedule.plist"]; }
- (BOOL)enabled { return [self.configuration[@"enabled"] boolValue]; }
- (BOOL)friendProtectionEnabled { return self.protectionUnavailable || self.configuration[@"friendProtection"] != nil; }
- (NSError *)errorWithMessage:(NSString *)message {
    return [NSError errorWithDomain:@"SelfControl.Schedule" code:2 userInfo:@{NSLocalizedDescriptionKey:message}];
}
- (BOOL)securePath:(NSString *)path directory:(BOOL)directory {
    struct stat s;
    if (lstat(path.fileSystemRepresentation, &s) != 0) return NO;
    return s.st_uid == 0 && !(s.st_mode & (S_IWGRP | S_IWOTH)) && (directory ? S_ISDIR(s.st_mode) : S_ISREG(s.st_mode));
}
- (BOOL)persist:(NSDictionary *)configuration error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:self.storageDirectory] &&
        ![fm createDirectoryAtPath:self.storageDirectory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:error]) return NO;
    if (![self securePath:self.storageDirectory directory:YES] ||
        ([fm fileExistsAtPath:self.storagePath] && ![self securePath:self.storagePath directory:NO])) {
        if (error) *error = [self errorWithMessage:@"The schedule storage folder must be owned by the system and protected from other users."];
        return NO;
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:configuration format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    // Create the temporary file as private from its first byte, then atomically replace.
    NSString *temporary = [self.storageDirectory stringByAppendingPathComponent:[@".settings-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) { if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil]; return NO; }
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    int failure = 0;
    while (remaining) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { failure = errno ?: EIO; break; }
        bytes += written; remaining -= (NSUInteger)written;
    }
    if (!failure && fsync(fd) != 0) failure = errno;
    if (close(fd) != 0 && !failure) failure = errno;
    if (!failure && rename(temporary.fileSystemRepresentation, self.storagePath.fileSystemRepresentation) != 0) failure = errno;
    if (failure) {
        unlink(temporary.fileSystemRepresentation);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:failure userInfo:nil];
        return NO;
    }
    return YES;
}
- (void)start {
    dispatch_async(self.queue, ^{
        if ([self securePath:self.storageDirectory directory:YES] && [self securePath:self.storagePath directory:NO]) {
            NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:self.storagePath];
            NSError *error;
            NSDictionary *validated = [SCWeeklySchedule validatedConfiguration:saved error:&error];
            NSNumber *uid = saved[@"controllingUID"];
            if (validated && [uid isKindOfClass:NSNumber.class] && uid.unsignedIntValue > 0) {
                NSMutableDictionary *c = [validated mutableCopy];
                c[@"controllingUID"] = uid;
                if (saved[@"friendProtection"]) {
                    if ([SCFriendProtection validRecord:saved[@"friendProtection"]]) {
                        c[@"friendProtection"] = saved[@"friendProtection"];
                        self.failedPasswordAttempts = MIN(4, [saved[@"friendProtection"][@"failedAttempts"] unsignedIntegerValue]);
                        id retry = saved[@"friendProtection"][@"retryAfter"];
                        if ([retry isKindOfClass:NSDate.class]) self.passwordRetryAfter = retry;
                    }
                    else self.protectionUnavailable = YES;
                }
                self.configuration = c;
            } else {
                self.protectionUnavailable = YES;
                self.lastError = error.localizedDescription ?: @"Could not load protected settings. Changes remain locked.";
            }
        } else if ([NSFileManager.defaultManager fileExistsAtPath:self.storagePath]) {
            self.protectionUnavailable = YES;
            self.lastError = @"Protected settings are unavailable. Changes remain locked.";
        }
        [self evaluate];
    });
    self.timer = [NSTimer timerWithTimeInterval:5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)tick:(NSTimer *)timer {
    if (self.tickPending) return;
    self.tickPending = YES;
    dispatch_async(self.queue, ^{ [self evaluate]; self.tickPending = NO; });
}
- (void)getStatus:(void (^)(NSDictionary *))reply {
    dispatch_async(self.queue, ^{
        NSMutableDictionary *status = [NSMutableDictionary dictionaryWithDictionary:self.configuration ?: @{}];
        [status removeObjectForKey:@"friendProtection"];
        status[@"friendProtectionEnabled"] = @(self.friendProtectionEnabled);
        status[@"browserIntegrationVersion"] = @1;
        if (self.lastError) status[@"lastError"] = self.lastError;
        reply(status);
    });
}
- (void)setConfiguration:(NSDictionary *)configuration controllingUID:(uid_t)uid reply:(void (^)(NSError *))reply {
    [self setConfiguration:configuration controllingUID:uid friendPassword:@"" reply:reply];
}
- (void)setConfiguration:(NSDictionary *)configuration controllingUID:(uid_t)uid friendPassword:(NSString *)password reply:(void (^)(NSError *))reply {
    dispatch_async(self.queue, ^{
        NSError *error;
        if ([configuration isKindOfClass:NSDictionary.class] && configuration[@"expectedBlocklist"] && ![configuration[@"expectedBlocklist"] isEqual:self.configuration[@"blocklist"] ?: @[]]) {
            reply([NSError errorWithDomain:@"SelfControl.Schedule" code:6 userInfo:@{NSLocalizedDescriptionKey:@"The shared blocklist changed. Refresh and retry this edit."}]); return;
        }
        NSDictionary *validated = [SCWeeklySchedule validatedConfiguration:configuration error:&error];
        if (!validated || uid == 0) { reply(error ?: [self errorWithMessage:@"A schedule must belong to a signed-in user."]); return; }
        error = [self commitConfiguration:validated uid:uid password:password];
        reply(error);
        if (!error) [self evaluate];
    });
}
- (void)prepareBrowserIntegration:(NSDictionary *)policy controllingUID:(uid_t)uid reply:(void (^)(NSError *))reply {
    dispatch_async(self.queue, ^{
        if (![policy isKindOfClass:NSDictionary.class] || !uid || self.protectionUnavailable) { reply([self errorWithMessage:@"Shared settings are unavailable. Open SelfControl to resolve setup."]); return; }
        if (self.configuration) {
            if ([self.configuration[@"controllingUID"] unsignedIntValue] != uid)
                reply([self errorWithMessage:@"The shared blocklist belongs to another Mac user."]);
            else if ([self.configuration[@"isAllowlist"] boolValue])
                reply([self errorWithMessage:@"The browser extension requires blocklist mode."]);
            else reply(nil);
            return;
        }
        NSLock *lock = SCDaemonBlockMethods.daemonMethodLock;
        if (![lock lockBeforeDate:[NSDate dateWithTimeIntervalSinceNow:5]]) { reply([self errorWithMessage:@"SelfControl is busy. Try setup again."]); return; }
        NSError *error;
        if ([SCBlockUtilities legacyBlockIsRunning]) error = [self errorWithMessage:@"Finish the legacy block before setting up browser integration."];
        NSDictionary *initialPolicy = [SCBlockUtilities anyBlockIsRunning] ? self.activePolicy : policy;
        NSDictionary *candidate = [self configurationWithPolicy:initialPolicy uid:uid];
        NSDictionary *validated = [SCWeeklySchedule validatedConfiguration:candidate error:&error];
        if (validated && [validated[@"isAllowlist"] boolValue]) error = [self errorWithMessage:@"The browser extension requires blocklist mode."];
        if (validated && !error) {
            NSMutableDictionary *c = [validated mutableCopy]; c[@"controllingUID"] = @(uid);
            if ([self persist:c error:&error]) { self.configuration = c; self.lastError = nil; }
        }
        [lock unlock];
        if (!error) [SCHelperToolUtilities sendConfigurationChangedNotification];
        reply(error);
    });
}

- (void)requestWebsiteBreak:(NSString *)domain controllingUID:(uid_t)uid reply:(void (^)(NSError *))reply {
    dispatch_async(self.queue, ^{
        NSLock *lock = SCDaemonBlockMethods.daemonMethodLock;
        if (![lock lockBeforeDate:[NSDate dateWithTimeIntervalSinceNow:5]]) {
            reply([self errorWithMessage:@"SelfControl is busy. Try again shortly."]); return;
        }
        SCSettings *settings = SCSettings.sharedSettings;
        if (![[settings valueForKey:@"BlockControllingUID"] unsignedIntValue] && !self.protectionUnavailable &&
            uid && [self.configuration[@"controllingUID"] unsignedIntValue] == uid) {
            [settings setValue:@(uid) forKey:@"BlockControllingUID"];
        }
        [lock unlock];
        [SCDaemonBlockMethods requestWebsiteBreak:domain controllingUID:uid reply:reply];
    });
}

- (void)appendBlockedWebsites:(NSArray<NSString *> *)domains controllingUID:(uid_t)uid reply:(void (^)(NSDictionary *, NSError *))reply {
    dispatch_async(self.queue, ^{
        NSDictionary *unchanged = @{@"saved":@NO, @"activeApplied":@NO, @"alreadyPresent":@NO};
        NSError *error;
        if (![SCWeeklySchedule validWebsiteDomains:domains]) error = [self errorWithMessage:@"Choose a public website with a valid domain name."];
        else if (self.protectionUnavailable) error = [self errorWithMessage:@"Protected settings are unavailable. Open SelfControl to resolve this."];
        else if (!self.configuration) error = [self errorWithMessage:@"Run browser integration setup before adding websites."];
        else if (!uid || [self.configuration[@"controllingUID"] unsignedIntValue] != uid) error = [self errorWithMessage:@"The shared blocklist belongs to another Mac user."];
        else if ([self.configuration[@"isAllowlist"] boolValue]) error = [self errorWithMessage:@"The browser extension requires blocklist mode."];
        if (error) { reply(unchanged, error); return; }
        NSLock *lock = SCDaemonBlockMethods.daemonMethodLock;
        if (![lock lockBeforeDate:[NSDate dateWithTimeIntervalSinceNow:5]]) { reply(unchanged, [self errorWithMessage:@"SelfControl is busy. Click again to retry."]); return; }
        BOOL active = [SCBlockUtilities anyBlockIsRunning] && ![SCBlockUtilities currentBlockIsExpired];
        if ([SCBlockUtilities legacyBlockIsRunning] || (active && [SCSettings.sharedSettings boolForKey:@"ActiveBlockAsWhitelist"])) {
            [lock unlock]; reply(unchanged, [self errorWithMessage:@"A legacy or allowlist block is running. Try again after it ends."]); return;
        }
        NSMutableOrderedSet *sites = [NSMutableOrderedSet orderedSetWithArray:self.configuration[@"blocklist"]];
        NSUInteger before = sites.count;
        [sites addObjectsFromArray:domains];
        BOOL alreadyPresent = before == sites.count;
        if (sites.count > 10000) { [lock unlock]; reply(unchanged, [self errorWithMessage:@"The shared blocklist has reached its website limit."]); return; }
        NSMutableDictionary *c = [self.configuration mutableCopy]; c[@"blocklist"] = sites.array;
        if (!alreadyPresent && ![self persist:c error:&error]) { [lock unlock]; reply(unchanged, error); return; }
        self.configuration = c;
        if (active) {
            NSArray *activeSites = [SCSettings.sharedSettings valueForKey:@"ActiveBlocklist"] ?: @[];
            for (NSString *domain in domains) if (![activeSites containsObject:domain]) alreadyPresent = NO;
            error = [SCDaemonBlockMethods appendBlocklistWhileLocked:domains];
        }
        self.lastError = error.localizedDescription;
        NSDictionary *result = @{@"saved":@YES, @"activeApplied":[NSNumber numberWithBool:active && !error], @"alreadyPresent":[NSNumber numberWithBool:alreadyPresent && !error]};
        [lock unlock];
        [SCHelperToolUtilities sendConfigurationChangedNotification];
        reply(result, error);
    });
}

- (void)appendBlocklist:(NSArray<NSString *> *)entries reply:(void (^)(NSError *))reply {
    dispatch_async(self.queue, ^{
        if (self.protectionUnavailable) { reply([SCFriendProtection error:SCFriendProtectionUnavailable message:@"Protected settings are unavailable. Changes remain locked."]); return; }
        if (!self.configuration || [self.configuration[@"isAllowlist"] boolValue]) { reply(nil); return; }
        NSMutableOrderedSet *sites = [NSMutableOrderedSet orderedSetWithArray:self.configuration[@"blocklist"]];
        [sites addObjectsFromArray:[SCMiscUtilities cleanBlocklist:entries]];
        NSMutableDictionary *c = [self.configuration mutableCopy];
        c[@"blocklist"] = sites.array;
        NSError *error;
        if (![self persist:c error:&error]) { self.lastError = error.localizedDescription; reply(error); return; }
        self.configuration = c;
        self.lastError = nil;
        [SCHelperToolUtilities sendConfigurationChangedNotification];
        reply(nil);
    });
}

// All approval checks and corresponding writes run on the same serial queue.
// No administrator credential or reusable 'unlocked' session substitutes for this password.
- (void)persistPasswordAttempts {
    if (!self.configuration[@"friendProtection"]) return;
    NSMutableDictionary *record = [self.configuration[@"friendProtection"] mutableCopy];
    record[@"failedAttempts"] = @(self.failedPasswordAttempts);
    if (self.passwordRetryAfter) record[@"retryAfter"] = self.passwordRetryAfter;
    else [record removeObjectForKey:@"retryAfter"];
    NSMutableDictionary *c = [self.configuration mutableCopy]; c[@"friendProtection"] = record;
    NSError *error;
    if ([self persist:c error:&error]) self.configuration = c;
    else self.lastError = @"Could not persist password attempt limits. Protected changes remain subject to password verification.";
}
- (NSError *)verifyFriendPassword:(NSString *)password {
    if (self.protectionUnavailable) return [SCFriendProtection error:SCFriendProtectionUnavailable message:@"Protected settings are unavailable. Changes remain locked."];
    if (!self.configuration[@"friendProtection"]) return nil;
    if (![password isKindOfClass:NSString.class] || !password.length) return [SCFriendProtection error:SCFriendPasswordRequired message:@"Your friend's password is required for this change."];
    if (self.passwordRetryAfter.timeIntervalSinceNow > 0)
        return [SCFriendProtection error:SCFriendPasswordThrottled message:@"Too many incorrect passwords. Wait one minute and try again."];
    if (![SCFriendProtection password:password matchesRecord:self.configuration[@"friendProtection"]]) {
        self.failedPasswordAttempts++;
        if (self.failedPasswordAttempts >= 5) { self.failedPasswordAttempts = 0; self.passwordRetryAfter = [NSDate dateWithTimeIntervalSinceNow:60]; }
        [self persistPasswordAttempts];
        return [SCFriendProtection error:SCFriendPasswordIncorrect message:@"That is not the friend's password. Protection was not changed."];
    }
    BOOL hadAttempts = self.failedPasswordAttempts > 0 || self.passwordRetryAfter != nil;
    self.failedPasswordAttempts = 0; self.passwordRetryAfter = nil;
    if (hadAttempts) [self persistPasswordAttempts];
    return nil;
}
- (NSError *)approveConfiguration:(NSDictionary *)proposed password:(NSString *)password {
    if (self.protectionUnavailable) return [self verifyFriendPassword:password];
    BOOL reduction = [SCFriendProtection reductionReasonsFor:proposed comparedTo:self.configuration].count > 0;
    if ([SCBlockUtilities anyBlockIsRunning]) {
        reduction |= [SCFriendProtection reductionReasonsFor:proposed comparedTo:self.activePolicy].count > 0;
        NSDate *end = [self effectiveEndForConfiguration:proposed manualEnd:self.manualEndForCurrentBlock];
        reduction |= [end timeIntervalSinceDate:[SCSettings.sharedSettings valueForKey:@"BlockEndDate"]] < -1;
    }
    if (!self.friendProtectionEnabled || !reduction) return nil;
    return [self verifyFriendPassword:password];
}
- (NSDate *)scheduledEndForConfiguration:(NSDictionary *)configuration {
    if (![configuration[@"enabled"] boolValue]) return nil;
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = NSTimeZone.localTimeZone;
    return [SCWeeklySchedule activeEndDateForSlots:configuration[@"slots"] atDate:NSDate.date calendar:calendar];
}
- (NSDictionary *)activePolicy {
    SCSettings *settings = SCSettings.sharedSettings;
    NSMutableDictionary *options = [NSMutableDictionary new];
    for (NSString *key in SCWeeklySchedule.blockSettingKeys) options[key] = [settings valueForKey:key] ?: @0;
    return @{@"blocklist":[settings valueForKey:@"ActiveBlocklist"] ?: @[],
        @"isAllowlist":@([settings boolForKey:@"ActiveBlockAsWhitelist"]), @"blockSettings":options};
}
- (NSDate *)manualEndForCurrentBlock {
    SCSettings *settings = SCSettings.sharedSettings;
    if ([settings boolForKey:@"ScheduleManagedBlock"]) return [settings valueForKey:@"ManualBlockEndDate"] ?: NSDate.distantPast;
    // Migrate blocks started before provenance was recorded. Recognize the saved
    // schedule only when its current interval, list, and mode match exactly.
    NSDate *current = [settings valueForKey:@"BlockEndDate"] ?: NSDate.distantPast;
    NSDate *scheduled = [self scheduledEndForConfiguration:self.configuration];
    if (scheduled && fabs([scheduled timeIntervalSinceDate:current]) < 1 &&
        [self.configuration[@"blocklist"] isEqual:[settings valueForKey:@"ActiveBlocklist"]] &&
        [self.configuration[@"isAllowlist"] boolValue] == [settings boolForKey:@"ActiveBlockAsWhitelist"])
        return NSDate.distantPast;
    return current;
}
- (NSDate *)effectiveEndForConfiguration:(NSDictionary *)configuration manualEnd:(NSDate *)manual {
    NSDate *scheduled = [self scheduledEndForConfiguration:configuration];
    return scheduled && [scheduled compare:manual] == NSOrderedDescending ? scheduled : manual;
}
- (NSError *)commitConfiguration:(NSDictionary *)validated uid:(uid_t)uid password:(NSString *)password {
    NSLock *lock = SCDaemonBlockMethods.daemonMethodLock;
    if (![lock lockBeforeDate:[NSDate dateWithTimeIntervalSinceNow:5]]) return [self errorWithMessage:@"SelfControl is busy. Try saving again."];
    NSError *error = [self approveConfiguration:validated password:password];
    if (error) { [lock unlock]; return error; }
    BOOL active = [SCBlockUtilities anyBlockIsRunning];
    if (active && [SCBlockUtilities legacyBlockIsRunning]) {
        [lock unlock]; return [self errorWithMessage:@"This block was started by an older SelfControl version. It must finish before its rules can be edited."];
    }
    NSDate *manual = active ? self.manualEndForCurrentBlock : NSDate.distantPast;
    NSDictionary *previous = self.configuration;
    NSMutableDictionary *c = [validated mutableCopy]; c[@"controllingUID"] = @(uid);
    if (previous[@"friendProtection"]) c[@"friendProtection"] = previous[@"friendProtection"];
    if (![self persist:c error:&error]) { [lock unlock]; return error; }
    if (active) {
        SCSettings *settings = SCSettings.sharedSettings;
        id oldManaged = [settings valueForKey:@"ScheduleManagedBlock"] ?: @NO;
        id oldManual = [settings valueForKey:@"ManualBlockEndDate"] ?: NSDate.distantPast;
        [settings setValue:@YES forKey:@"ScheduleManagedBlock"];
        [settings setValue:manual forKey:@"ManualBlockEndDate"];
        error = [SCDaemonBlockMethods applyApprovedPolicyWhileLocked:c endDate:[self effectiveEndForConfiguration:c manualEnd:manual]];
        if (error) {
            [settings setValue:oldManaged forKey:@"ScheduleManagedBlock"];
            [settings setValue:oldManual forKey:@"ManualBlockEndDate"];
            [settings syncSettingsAndWait:5];
            NSError *rollback;
            if (![self persist:previous ?: @{} error:&rollback]) {
                self.protectionUnavailable = YES;
                self.lastError = @"Could not restore the saved policy after a failed active-block update. Changes remain locked.";
            }
            [lock unlock]; return error;
        }
    }
    self.configuration = c; self.lastError = nil;
    [lock unlock];
    [SCHelperToolUtilities sendConfigurationChangedNotification];
    return nil;
}
- (NSDictionary *)configurationWithPolicy:(NSDictionary *)policy uid:(uid_t)uid {
    NSMutableDictionary *c = [NSMutableDictionary dictionaryWithDictionary:self.configuration ?: @{@"slots":@[], @"enabled":@NO}];
    for (NSString *key in @[@"blocklist", @"isAllowlist", @"blockSettings"]) {
        if (policy[key]) c[key] = policy[key];
    }
    c[@"controllingUID"] = @(uid);
    return c;
}
- (NSError *)applySharedPolicy:(NSDictionary *)policy uid:(uid_t)uid password:(NSString *)password {
    if (![policy isKindOfClass:NSDictionary.class] || !uid) return [self errorWithMessage:@"Invalid shared blocklist settings."];
    if (policy[@"expectedBlocklist"] && ![policy[@"expectedBlocklist"] isEqual:self.configuration[@"blocklist"] ?: @[]])
        return [NSError errorWithDomain:@"SelfControl.Schedule" code:6 userInfo:@{NSLocalizedDescriptionKey:@"The shared blocklist changed. Refresh and retry this edit."}];
    NSDictionary *candidate = [self configurationWithPolicy:policy uid:uid];
    NSError *error;
    NSDictionary *validated = [SCWeeklySchedule validatedConfiguration:candidate error:&error];
    if (!validated) return error;
    return [self commitConfiguration:validated uid:uid password:password];
}
- (void)setSharedPolicy:(NSDictionary *)policy controllingUID:(uid_t)uid friendPassword:(NSString *)password reply:(void (^)(NSError *))reply {
    dispatch_async(self.queue, ^{ reply([self applySharedPolicy:policy uid:uid password:password]); });
}
- (void)setFriendPassword:(NSString *)password policy:(NSDictionary *)policy controllingUID:(uid_t)uid reply:(void (^)(NSError *))reply {
    dispatch_async(self.queue, ^{
        if (self.friendProtectionEnabled) { reply([SCFriendProtection error:SCFriendPasswordRequired message:@"A friend's password is already set. Turn off protection with that password before setting a new one."]); return; }
        if (![policy isKindOfClass:NSDictionary.class]) { reply([self errorWithMessage:@"Invalid shared blocklist settings."]); return; }
        NSError *error;
        NSDictionary *record = [SCFriendProtection recordForPassword:password error:&error];
        if (!record) { reply(error); return; }
        NSDictionary *candidate = [self configurationWithPolicy:policy uid:uid];
        NSDictionary *validated = [SCWeeklySchedule validatedConfiguration:candidate error:&error];
        if (!validated || !uid) { reply(error ?: [self errorWithMessage:@"Invalid user for password setup."]); return; }
        NSMutableDictionary *c = [validated mutableCopy];
        c[@"controllingUID"] = @(uid); c[@"friendProtection"] = record;
        if (![self persist:c error:&error]) { reply(error); return; }
        self.configuration = c; self.lastError = nil;
        [SCHelperToolUtilities sendConfigurationChangedNotification]; reply(nil);
    });
}
- (void)disableFriendPassword:(NSString *)password reply:(void (^)(NSError *))reply {
    dispatch_async(self.queue, ^{
        NSError *error = [self verifyFriendPassword:password];
        if (error) { reply(error); return; }
        if (!self.friendProtectionEnabled) { reply(nil); return; }
        NSMutableDictionary *c = [self.configuration mutableCopy];
        [c removeObjectForKey:@"friendProtection"];
        if (![self persist:c error:&error]) { reply(error); return; }
        self.configuration = c; self.lastError = nil;
        [SCHelperToolUtilities sendConfigurationChangedNotification]; reply(nil);
    });
}
- (void)startManualBlockWithControllingUID:(uid_t)uid blocklist:(NSArray *)sites isAllowlist:(BOOL)isAllowlist endDate:(NSDate *)endDate blockSettings:(NSDictionary *)settings authorization:(NSData *)authorization reply:(void (^)(NSError *))reply {
    dispatch_async(self.queue, ^{
        if ([SCBlockUtilities anyBlockIsRunning]) { reply([self errorWithMessage:@"A block is already running."]); return; }
        if (self.configuration || self.protectionUnavailable) {
            NSError *error = [self applySharedPolicy:@{@"blocklist":sites, @"isAllowlist":@(isAllowlist), @"blockSettings":settings} uid:uid password:@""];
            if (error) { reply(error); return; }
        }
        [SCDaemonBlockMethods startBlockWithControllingUID:uid blocklist:sites isAllowlist:isAllowlist endDate:endDate blockSettings:settings authorization:authorization reply:reply];
    });
}

- (void)evaluate {
    if (!self.enabled) return;
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = NSTimeZone.localTimeZone;
    NSDictionary *c = self.configuration;
    NSDate *end = [SCWeeklySchedule activeEndDateForSlots:c[@"slots"] atDate:NSDate.date calendar:calendar];
    if (!end) return;
    if ([SCBlockUtilities anyBlockIsRunning]) {
        if ([SCBlockUtilities currentBlockIsExpired]) { [SCDaemonBlockMethods checkupBlock]; return; }
        SCSettings *settings = SCSettings.sharedSettings;
        BOOL allowlist = [c[@"isAllowlist"] boolValue];
        if (allowlist != [settings boolForKey:@"ActiveBlockAsWhitelist"]) {
            self.lastError = @"The manual block uses a different list mode. Scheduled blocking will resume after it ends.";
            return;
        }
        if (!allowlist) {
            NSMutableOrderedSet *sites = [NSMutableOrderedSet orderedSetWithArray:[settings valueForKey:@"ActiveBlocklist"] ?: @[]];
            NSUInteger previous = sites.count;
            [sites addObjectsFromArray:c[@"blocklist"]];
            if (sites.count != previous) [SCDaemonBlockMethods updateBlocklist:sites.array authorization:NSData.data reply:^(NSError *error) { if (error) self.lastError = error.localizedDescription; }];
        } else if (![[settings valueForKey:@"ActiveBlocklist"] isEqual:c[@"blocklist"]]) {
            self.lastError = @"The manual allowlist differs from the saved schedule. Scheduled blocking will resume after it ends.";
            return;
        }
        NSDate *oldEnd = [settings valueForKey:@"BlockEndDate"];
        // Renew a continuously selected week only near expiry, avoiding constant writes.
        BOOL fullWeek = [SCWeeklySchedule indexesFromSlots:c[@"slots"]].count == 336;
        if ([end timeIntervalSinceDate:oldEnd] > 1 && (!fullWeek || oldEnd.timeIntervalSinceNow < 60)) {
            NSDate *extension = [end timeIntervalSinceDate:oldEnd] > 86400 ? [oldEnd dateByAddingTimeInterval:86400] : end;
            [SCDaemonBlockMethods extendScheduledBlockTo:extension reply:^(NSError *error) { if (error) self.lastError = error.localizedDescription; }];
        }
        return;
    }
    [SCDaemonBlockMethods startBlockWithControllingUID:[c[@"controllingUID"] unsignedIntValue] blocklist:c[@"blocklist"]
        isAllowlist:[c[@"isAllowlist"] boolValue] endDate:end blockSettings:c[@"blockSettings"] scheduled:YES authorization:NSData.data
        reply:^(NSError *error) { self.lastError = error.localizedDescription; }];
}
@end
