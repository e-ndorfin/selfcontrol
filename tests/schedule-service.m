#import "SCScheduleService.h"
#import "SCDaemonBlockMethods.h"
#import "SCWeeklySchedule.h"
#import "SCFriendProtection.h"
#import <sys/stat.h>
#import <unistd.h>

static BOOL active, expired, failActiveUpdate, legacy;
static NSUInteger starts, updates, extensions, checks;
static NSMutableDictionary *block;
@implementation SCBlockUtilities
+ (BOOL)anyBlockIsRunning { return active; }
+ (BOOL)currentBlockIsExpired { return expired; }
+ (BOOL)legacyBlockIsRunning { return legacy; }
@end
@implementation SCSettings
+ (instancetype)sharedSettings { static SCSettings *s; if (!s) s = [self new]; return s; }
- (id)valueForKey:(NSString *)key { return block[key]; }
- (BOOL)boolForKey:(NSString *)key { return [block[key] boolValue]; }
- (void)setValue:(id)value forKey:(NSString *)key { if (!block) block = [NSMutableDictionary new]; block[key] = value; }
- (NSError *)syncSettingsAndWait:(NSTimeInterval)timeout { return nil; }
@end
@implementation SCMiscUtilities
+ (NSArray *)cleanBlocklist:(NSArray *)entries { return entries; }
@end
@implementation SCHelperToolUtilities
+ (void)sendConfigurationChangedNotification {}
@end
@implementation SCDaemonBlockMethods
+ (void)requestWebsiteBreak:(NSString *)domain controllingUID:(uid_t)uid reply:(void (^)(NSError *))reply { reply(nil); }
+ (NSLock *)daemonMethodLock { static NSLock *lock; if (!lock) lock = [NSLock new]; return lock; }
+ (void)startBlockWithControllingUID:(uid_t)uid blocklist:(NSArray *)list isAllowlist:(BOOL)allowlist endDate:(NSDate *)end blockSettings:(NSDictionary *)settings authorization:(NSData *)authorization reply:(void (^)(NSError *))reply {
    [self startBlockWithControllingUID:uid blocklist:list isAllowlist:allowlist endDate:end blockSettings:settings scheduled:NO authorization:authorization reply:reply];
}
+ (void)startBlockWithControllingUID:(uid_t)uid blocklist:(NSArray *)list isAllowlist:(BOOL)allowlist endDate:(NSDate *)end blockSettings:(NSDictionary *)settings scheduled:(BOOL)scheduled authorization:(NSData *)authorization reply:(void (^)(NSError *))reply {
    starts++; active = YES;
    block = [settings mutableCopy];
    [block addEntriesFromDictionary:@{@"ActiveBlocklist":list, @"ActiveBlockAsWhitelist":@(allowlist), @"BlockEndDate":end,
        @"ScheduleManagedBlock":@YES, @"ManualBlockEndDate":scheduled ? NSDate.distantPast : end}]; reply(nil);
}
+ (NSError *)appendBlocklistWhileLocked:(NSArray *)sites {
    if (failActiveUpdate) return [NSError errorWithDomain:@"Test" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Simulated active failure"}];
    NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:block[@"ActiveBlocklist"] ?: @[]];
    [merged addObjectsFromArray:sites]; block[@"ActiveBlocklist"] = merged.array; updates++;
    return nil;
}
+ (void)updateBlocklist:(NSArray *)list authorization:(NSData *)auth reply:(void (^)(NSError *))reply { updates++; block[@"ActiveBlocklist"] = list; reply(nil); }
+ (void)updateBlockEndDate:(NSDate *)date authorization:(NSData *)auth reply:(void (^)(NSError *))reply { extensions++; block[@"BlockEndDate"] = date; reply(nil); }
+ (void)extendScheduledBlockTo:(NSDate *)date reply:(void (^)(NSError *))reply { [self updateBlockEndDate:date authorization:NSData.data reply:reply]; }
+ (NSError *)applyApprovedPolicyWhileLocked:(NSDictionary *)policy endDate:(NSDate *)end {
    if (failActiveUpdate) return [NSError errorWithDomain:@"Test" code:2 userInfo:nil];
    active = end.timeIntervalSinceNow > 0 && ([policy[@"isAllowlist"] boolValue] || [policy[@"blocklist"] count]);
    block[@"BlockEndDate"] = end; block[@"ActiveBlocklist"] = policy[@"blocklist"];
    block[@"ActiveBlockAsWhitelist"] = policy[@"isAllowlist"];
    [block addEntriesFromDictionary:policy[@"blockSettings"]];
    return nil;
}
+ (void)checkupBlock { active = NO; expired = NO; }
+ (void)checkBlockIntegrity {}
@end
@interface SCScheduleService (Testing)
- (void)evaluate;
- (BOOL)securePath:(NSString *)path directory:(BOOL)directory;
@end
@interface MemoryScheduleService : SCScheduleService
@property NSDictionary *persisted;
@property BOOL failPersistence;
@end
@implementation MemoryScheduleService
- (BOOL)persist:(NSDictionary *)configuration error:(NSError **)error {
    if (self.failPersistence) { if (error) *error = [NSError errorWithDomain:@"Test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulated disk failure"}]; return NO; }
    self.persisted = [configuration copy]; return YES;
}
@end
@interface DiskScheduleService : SCScheduleService
@property NSString *testDirectory;
@end
@implementation DiskScheduleService
- (NSString *)storageDirectory { return self.testDirectory; }
- (BOOL)securePath:(NSString *)path directory:(BOOL)directory {
    struct stat s;
    if (lstat(path.fileSystemRepresentation, &s) != 0) return NO;
    return s.st_uid == geteuid() && !(s.st_mode & (S_IWGRP|S_IWOTH)) && (directory ? S_ISDIR(s.st_mode) : S_ISREG(s.st_mode));
}
@end
static void check(BOOL passed, NSString *message) {
    checks++;
    if (!passed) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void waitFor(dispatch_semaphore_t semaphore) {
    check(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, @"async daemon callback completes");
}
static NSDictionary *status(MemoryScheduleService *service) {
    __block NSDictionary *result;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [service getStatus:^(NSDictionary *s) { result = s; dispatch_semaphore_signal(done); }]; waitFor(done); return result;
}
static NSError *save(MemoryScheduleService *service, NSDictionary *config) {
    __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [service setConfiguration:config controllingUID:501 reply:^(NSError *e) { error = e; dispatch_semaphore_signal(done); }]; waitFor(done);
    (void)status(service); // Also waits for evaluation following the save.
    return error;
}
static NSError *append(MemoryScheduleService *service, NSArray *sites) {
    __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [service appendBlocklist:sites reply:^(NSError *e) { error = e; dispatch_semaphore_signal(done); }]; waitFor(done); return error;
}
static NSError *approvedSave(MemoryScheduleService *service, NSDictionary *configuration, NSString *password) {
    __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [service setConfiguration:configuration controllingUID:501 friendPassword:password reply:^(NSError *e) { error=e; dispatch_semaphore_signal(done); }]; waitFor(done);
    (void)status(service); return error;
}
static NSDictionary *browserAppend(MemoryScheduleService *service, id sites, uid_t uid) {
    __block NSDictionary *result;
    __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [service appendBlockedWebsites:sites controllingUID:uid reply:^(NSDictionary *r, NSError *e) { result=r; error=e; dispatch_semaphore_signal(done); }];
    waitFor(done);
    NSMutableDictionary *response = [result mutableCopy]; response[@"ok"] = @(!error);
    if (error) response[@"errorCode"] = @(error.code);
    return response;
}
static NSError *browserSetup(MemoryScheduleService *service, NSDictionary *policy) {
    __block NSError *error;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [service prepareBrowserIntegration:policy controllingUID:501 reply:^(NSError *e) { error=e; dispatch_semaphore_signal(done); }];
    waitFor(done); return error;
}
int main(void) {
    @autoreleasepool {
        MemoryScheduleService *service = [MemoryScheduleService new];
        NSMutableDictionary *settings = [NSMutableDictionary new];
        for (NSString *key in SCWeeklySchedule.blockSettingKeys) settings[key] = @0;
        NSMutableDictionary *config = [@{@"slots":@[@18, @19], @"enabled":@NO, @"isAllowlist":@NO,
            @"blocklist":@[@"example.com"], @"blockSettings":settings} mutableCopy];
        check(save(service, config) == nil && !service.enabled, @"disabled schedule persists without starting a block");
        check([service.persisted[@"controllingUID"] isEqual:@501] && starts == 0, @"daemon records the authenticated user");
        check(append(service, @[@"news.example", @"example.com"]) == nil, @"website additions persist");
        NSDictionary *saved = status(service);
        check([saved[@"blocklist"] isEqual:@[@"example.com", @"news.example"]], @"websites merged without duplicates");
        check([saved[@"slots"] isEqual:@[@18, @19]] && ![saved[@"enabled"] boolValue], @"website additions leave timing and enable state intact");
        active = YES;
        config[@"slots"] = @[@20];
        check(save(service, config) == nil, @"active timing edits are unrestricted when no password is set");
        check([status(service)[@"slots"] isEqual:@[@20]], @"active edit persists the proposed schedule");
        check(append(service, @[@"video.example"]) == nil, @"website additions remain possible during active blocks");
        active = NO;
        service.failPersistence = YES;
        check(save(service, config) != nil && [status(service)[@"slots"] isEqual:@[@20]], @"disk failure preserves last saved configuration");
        check(append(service, @[@"failed.example"]) != nil && ![status(service)[@"blocklist"] containsObject:@"failed.example"], @"failed additions never report success");
        service.failPersistence = NO;
        NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        NSUInteger slot = [SCWeeklySchedule slotAtDate:NSDate.date calendar:cal];
        config[@"slots"] = @[@(slot), @((slot + 1) % 336)]; config[@"enabled"] = @YES;
        check(save(service, config) == nil && starts == 1 && active && service.enabled, @"saving inside a period starts scheduled enforcement");
        NSDate *scheduledEnd = block[@"BlockEndDate"];
        [service evaluate];
        check(starts == 1 && [block[@"BlockEndDate"] isEqual:scheduledEnd], @"repeated evaluation does not restart or extend a finite scheduled block");
        block[@"BlockEndDate"] = [NSDate dateWithTimeIntervalSinceNow:2 * 3600];
        NSDate *manualEnd = block[@"BlockEndDate"];
        [service evaluate];
        check([block[@"BlockEndDate"] isEqual:manualEnd], @"longer manual block is never shortened");
        block[@"BlockEndDate"] = [NSDate dateWithTimeIntervalSinceNow:60];
        block[@"ActiveBlocklist"] = @[@"manual.example"];
        [service evaluate];
        check(extensions == 1 && [block[@"BlockEndDate"] isEqual:scheduledEnd], @"shorter overlapping manual block extends through scheduled period");
        check(updates == 1 && [block[@"ActiveBlocklist"] containsObject:@"example.com"] && [block[@"ActiveBlocklist"] containsObject:@"manual.example"], @"manual and scheduled blocklists are combined");
        expired = YES;
        [service evaluate]; [service evaluate];
        check(starts == 2 && active, @"expired manual block is cleaned up and schedule resumes");
        check(![service securePath:NSHomeDirectory() directory:YES], @"user-writable schedule storage is rejected");
        active = NO;
        config[@"enabled"] = @NO; config[@"blocklist"] = @[@"example.com", @"news.example"];
        check(save(service, config) == nil && ![status(service)[@"friendProtectionEnabled"] boolValue], @"initial installation has no friend password");
        dispatch_semaphore_t passwordDone = dispatch_semaphore_create(0);
        __block NSError *passwordError;
        [service setFriendPassword:@"test-friend-password" policy:config controllingUID:501 reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError && service.friendProtectionEnabled, @"friend can enable password protection");
        check(!status(service)[@"friendProtection"] && !status(service)[@"hash"] && !status(service)[@"salt"], @"password verifier never leaves the helper's status API");
        NSDictionary *verifier = service.persisted[@"friendProtection"];
        config[@"blocklist"] = @[@"example.com"];
        check(save(service, config).code == SCFriendPasswordRequired, @"legacy password-less schedule API cannot reduce blocking");
        check([status(service)[@"blocklist"] containsObject:@"news.example"], @"failed approval leaves protected websites intact");
        check(append(service, @[@"video.example"]) == nil, @"adding blocked websites needs no friend password");
        NSMutableDictionary *fake = [config mutableCopy]; fake[@"friendProtection"] = @{};
        check(save(service, fake).code == SCFriendPasswordRequired, @"forged password metadata cannot disable protection");
        NSMutableDictionary *nonReducingForgery = [config mutableCopy];
        nonReducingForgery[@"blocklist"] = @[@"example.com", @"news.example", @"video.example"];
        nonReducingForgery[@"friendProtection"] = @{};
        check(save(service, nonReducingForgery) == nil && service.friendProtectionEnabled, @"extra metadata on a non-reducing save cannot switch protection off");
        check([service.persisted[@"friendProtection"][@"hash"] isEqual:verifier[@"hash"]], @"helper preserves its own verifier rather than client-supplied metadata");
        NSMutableDictionary *future = [nonReducingForgery mutableCopy];
        future[@"slots"] = @[@((slot + 10) % 336)]; future[@"enabled"] = @YES;
        check(save(service, future) == nil && !active, @"enabling future scheduled time needs no friend password");
        future[@"enabled"] = @NO;
        check(save(service, future).code == SCFriendPasswordRequired, @"disabling future scheduling is password protected by the helper");
        [service setConfiguration:future controllingUID:501 friendPassword:@"test-friend-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError && ![status(service)[@"enabled"] boolValue] && service.friendProtectionEnabled, @"friend can approve disabling scheduling without turning off password protection");
        [service setFriendPassword:@"my-new-password" policy:config controllingUID:501 reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(passwordError.code == SCFriendPasswordRequired && service.friendProtectionEnabled, @"setting another password cannot reset the existing one");
        [service disableFriendPassword:@"my-mac-admin-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(passwordError.code == SCFriendPasswordIncorrect && service.friendProtectionEnabled, @"administrator password cannot turn off friend protection");
        [service setConfiguration:config controllingUID:501 friendPassword:@"test-friend-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError && [status(service)[@"blocklist"] isEqual:@[@"example.com"]], @"friend password authorizes the exact reduction");
        check([service.persisted[@"friendProtection"][@"hash"] isEqual:verifier[@"hash"]], @"approved schedule edits do not replace the password");
        config[@"blocklist"] = @[];
        check(save(service, config).code == SCFriendPasswordRequired, @"approval of one change does not unlock subsequent reductions");
        config[@"blocklist"] = @[@"example.com",@"new.example"];
        check(save(service, config) == nil, @"stronger schedule saves without the friend password");
        [service startManualBlockWithControllingUID:501 blocklist:@[@"example.com"] isAllowlist:NO endDate:[NSDate dateWithTimeIntervalSinceNow:60] blockSettings:settings authorization:NSData.data reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(passwordError.code == SCFriendPasswordRequired && !active, @"manual/CLI block cannot use a weaker list to evade protection");
        [service setSharedPolicy:@{@"blocklist":@[@"example.com"], @"isAllowlist":@NO, @"blockSettings":settings} controllingUID:501 friendPassword:@"" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(passwordError.code == SCFriendPasswordRequired, @"shared list edits are enforced in the helper");
        service.failPersistence = YES;
        [service disableFriendPassword:@"test-friend-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(passwordError && service.friendProtectionEnabled, @"failed disable write cannot turn protection off");
        service.failPersistence = NO;
        for (NSUInteger i=0;i<5;i++) {
            [service disableFriendPassword:@"wrong-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        }
        [service disableFriendPassword:@"test-friend-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(passwordError.code == SCFriendPasswordThrottled && service.friendProtectionEnabled, @"repeated wrong passwords are throttled");
        check([service.persisted[@"friendProtection"][@"retryAfter"] isKindOfClass:NSDate.class], @"attempt throttle survives a helper restart");
        [service setValue:[NSDate dateWithTimeIntervalSinceNow:-1] forKey:@"passwordRetryAfter"];
        [service disableFriendPassword:@"test-friend-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError && !service.friendProtectionEnabled && !service.persisted[@"friendProtection"], @"turn off password requires the actual friend password");
        check([status(service)[@"blocklist"] isEqual:@[@"example.com",@"new.example"]], @"turning off the password preserves blocking settings");
        config[@"blocklist"] = @[@"example.com"];
        check(save(service, config) == nil, @"changes are unrestricted again after authorized password removal");

        MemoryScheduleService *master = [MemoryScheduleService new];
        NSMutableDictionary *running = [config mutableCopy];
        running[@"slots"] = @[@(slot), @((slot + 1) % 336), @((slot + 2) % 336)];
        running[@"enabled"] = @NO; running[@"blocklist"] = @[@"example.com", @"news.example"];
        check(save(master, running) == nil, @"master-key test begins with a disabled schedule");
        [master setFriendPassword:@"master-key-password" policy:running controllingUID:501 reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError, @"master-key password is set only in mock storage");
        running[@"enabled"] = @YES;
        check(save(master, running) == nil && active, @"stronger schedule starts without friend approval");
        NSDate *originalEnd = block[@"BlockEndDate"];
        check([block[@"ScheduleManagedBlock"] boolValue] && [block[@"ManualBlockEndDate"] timeIntervalSinceNow] < 0, @"scheduled start records that no separate manual timer exists");
        running[@"blocklist"] = @[@"example.com", @"news.example", @"video.example"];
        check(save(master, running) == nil && [block[@"ActiveBlocklist"] containsObject:@"video.example"], @"active website additions need no friend approval");
        NSMutableDictionary *reduced = [running mutableCopy]; reduced[@"blocklist"] = @[@"example.com", @"video.example"];
        check(save(master, reduced).code == SCFriendPasswordRequired, @"active website removal requires friend approval");
        check([block[@"ActiveBlocklist"] containsObject:@"news.example"] && [master.persisted[@"blocklist"] containsObject:@"news.example"], @"unapproved removal leaves active and saved lists unchanged");
        check(approvedSave(master, reduced, @"wrong-password").code == SCFriendPasswordIncorrect, @"wrong master key cannot remove an active website");
        check(approvedSave(master, reduced, @"master-key-password") == nil && ![block[@"ActiveBlocklist"] containsObject:@"news.example"], @"correct master key removes websites from the running block");
        check([block[@"BlockEndDate"] isEqual:originalEnd] && master.friendProtectionEnabled, @"website approval preserves timing and does not turn off protection");
        block[@"ActiveBlocklist"] = [block[@"ActiveBlocklist"] arrayByAddingObject:@"active-only.example"];
        check(save(master, reduced).code == SCFriendPasswordRequired && [block[@"ActiveBlocklist"] containsObject:@"active-only.example"], @"active restrictions absent from the saved policy still require approval to remove");
        check(approvedSave(master, reduced, @"master-key-password") == nil && ![block[@"ActiveBlocklist"] containsObject:@"active-only.example"], @"master key approves the exact active policy as well as future policy");
        reduced[@"slots"] = @[@(slot)];
        check(save(master, reduced).code == SCFriendPasswordRequired && [block[@"BlockEndDate"] isEqual:originalEnd], @"active schedule shortening cannot bypass fresh approval");
        check(approvedSave(master, reduced, @"master-key-password") == nil && active && [block[@"BlockEndDate"] compare:originalEnd] == NSOrderedAscending, @"approved active schedule shortening immediately changes its end time");
        NSMutableDictionary *off = [reduced mutableCopy]; off[@"enabled"] = @NO;
        check(save(master, off).code == SCFriendPasswordRequired && active, @"active schedule disable requires its own approval");
        check(approvedSave(master, off, @"master-key-password") == nil && !active && !master.enabled, @"approved schedule disable stops a schedule-only block immediately");
        check(save(master, reduced) == nil && active, @"schedule can be enabled again without a password");
        off[@"slots"] = @[@((slot + 8) % 336)]; off[@"enabled"] = @YES;
        check(approvedSave(master, off, @"master-key-password") == nil && !active && master.enabled, @"moving the current period to a future time stops only the current scheduled block");
        off[@"enabled"] = @NO;
        check(approvedSave(master, off, @"master-key-password") == nil && !master.enabled, @"future schedule can be disabled before starting a separate manual timer");
        NSDate *separateEnd = [NSDate dateWithTimeIntervalSinceNow:60];
        [master startManualBlockWithControllingUID:501 blocklist:reduced[@"blocklist"] isAllowlist:NO endDate:separateEnd blockSettings:settings authorization:NSData.data reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError && active && [block[@"ManualBlockEndDate"] isEqual:separateEnd], @"manual start records its own end time");
        check(save(master, reduced) == nil && [block[@"BlockEndDate"] compare:separateEnd] == NSOrderedDescending, @"overlapping schedule extends enforcement without replacing the manual end time");
        off[@"enabled"] = @NO;
        check(approvedSave(master, off, @"master-key-password") == nil && active && [block[@"BlockEndDate"] isEqual:separateEnd], @"approved schedule disable preserves an overlapping manual timer");
        off[@"blocklist"] = @[@"example.com"];
        [master setSharedPolicy:@{@"blocklist":off[@"blocklist"], @"isAllowlist":@NO, @"blockSettings":settings} controllingUID:501 friendPassword:@"master-key-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError && [block[@"ActiveBlocklist"] isEqual:@[@"example.com"]] && [block[@"BlockEndDate"] isEqual:separateEnd], @"shared-list editor can remove active websites with approval while the manual timer continues");
        NSMutableDictionary *mode = [off mutableCopy]; mode[@"isAllowlist"] = @YES;
        check(save(master, mode).code == SCFriendPasswordRequired, @"active list-mode change requires the master key");
        check(approvedSave(master, mode, @"master-key-password") == nil && [block[@"ActiveBlockAsWhitelist"] boolValue], @"approved active list-mode change replaces the enforced mode");
        mode[@"blocklist"] = @[@"example.com", @"allowed.example"];
        check(save(master, mode).code == SCFriendPasswordRequired, @"adding an allowed website during a block requires approval");
        check(approvedSave(master, mode, @"master-key-password") == nil && [block[@"ActiveBlocklist"] containsObject:@"allowed.example"], @"master key adds allowed websites to an active allowlist");
        mode[@"blocklist"] = @[@"example.com"];
        check(save(master, mode) == nil && ![block[@"ActiveBlocklist"] containsObject:@"allowed.example"], @"stronger active allowlist edits need no password");
        NSDictionary *beforeFailure = master.persisted;
        failActiveUpdate = YES; mode[@"blocklist"] = @[@"example.com", @"failed.example"];
        check(approvedSave(master, mode, @"master-key-password") != nil && [master.persisted isEqual:beforeFailure], @"failed active enforcement rolls back the saved configuration");
        check(![block[@"ActiveBlocklist"] containsObject:@"failed.example"] && master.friendProtectionEnabled, @"failed active enforcement preserves previous rules and password");
        failActiveUpdate = NO; master.failPersistence = YES;
        check(approvedSave(master, mode, @"master-key-password") != nil && ![block[@"ActiveBlocklist"] containsObject:@"failed.example"], @"disk failure prevents changes to active rules");
        master.failPersistence = NO; active = NO;

        MemoryScheduleService *migration = [MemoryScheduleService new];
        check(save(migration, running) == nil && active, @"migration test starts a current scheduled block");
        [block removeObjectForKey:@"ScheduleManagedBlock"]; [block removeObjectForKey:@"ManualBlockEndDate"];
        NSMutableDictionary *migratedOff = [running mutableCopy]; migratedOff[@"enabled"] = @NO;
        check(save(migration, migratedOff) == nil && !active, @"pre-update block matching the saved schedule is recognized as schedule-only");
        check(save(migration, running) == nil && active, @"migration schedule starts again");
        NSDate *unknownManual = [block[@"BlockEndDate"] dateByAddingTimeInterval:7200]; block[@"BlockEndDate"] = unknownManual;
        [block removeObjectForKey:@"ScheduleManagedBlock"]; [block removeObjectForKey:@"ManualBlockEndDate"];
        check(save(migration, migratedOff) == nil && active && [block[@"BlockEndDate"] isEqual:unknownManual], @"pre-update block that differs from the schedule preserves its existing manual end");
        active = NO;

        DiskScheduleService *disk = [DiskScheduleService new];
        disk.testDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"selfcontrol-password-tests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [disk setFriendPassword:@"disk-test-password" policy:config controllingUID:501 reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError && disk.friendProtectionEnabled, @"real atomic settings writer persists the password verifier");
        NSString *diskPath = [disk.testDirectory stringByAppendingPathComponent:@"WeeklySchedule.plist"];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:diskPath error:nil];
        check([attributes[NSFilePosixPermissions] unsignedIntValue] == 0600, @"password file is private from creation through atomic replacement");
        DiskScheduleService *restarted = [DiskScheduleService new]; restarted.testDirectory = disk.testDirectory;
        [restarted start];
        __block NSDictionary *reloaded;
        [restarted getStatus:^(NSDictionary *s) { reloaded=s; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(restarted.friendProtectionEnabled && [reloaded[@"blocklist"] isEqual:config[@"blocklist"]], @"password and approved policy survive a cold helper start");
        check(!reloaded[@"friendProtection"], @"reloaded status still hides the verifier");
        [restarted disableFriendPassword:@"wrong-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(passwordError.code == SCFriendPasswordIncorrect && restarted.friendProtectionEnabled, @"cold restart does not reset or bypass the friend password");
        [restarted disableFriendPassword:@"disk-test-password" reply:^(NSError *e) { passwordError=e; dispatch_semaphore_signal(passwordDone); }]; waitFor(passwordDone);
        check(!passwordError && ![NSDictionary dictionaryWithContentsOfFile:diskPath][@"friendProtection"] && !restarted.friendProtectionEnabled, @"authorized turn-off is persisted by the real writer");
        [NSFileManager.defaultManager removeItemAtPath:disk.testDirectory error:nil];
        active = NO; expired = NO; legacy = NO; failActiveUpdate = NO;
        MemoryScheduleService *browser = [MemoryScheduleService new];
        NSDictionary *browserPolicy = @{@"blocklist":@[@"example.com"], @"isAllowlist":@NO, @"blockSettings":settings};
        check(![browserAppend(browser, @[@"reddit.com"], 501)[@"ok"] boolValue], @"unconfigured browser integration fails rather than silently succeeding");
        check(browserSetup(browser, browserPolicy) == nil && !browser.enabled, @"browser setup creates a disabled shared policy");
        NSDictionary *initialBrowser = status(browser);
        check(browserSetup(browser, browserPolicy) == nil && [initialBrowser isEqual:status(browser)], @"repeated browser setup preserves the configuration");
        for (id bad in @[@[], @[@"https://reddit.com"], @[@"reddit.com", @"www.reddit.com", @"news.reddit.com"], @[@"*"], @[@"localhost"], @[@"127.0.0.1"], @[@"bad\nname.com"], @[@123], NSNull.null])
            check(![browserAppend(browser, bad, 501)[@"ok"] boolValue], @"browser endpoint rejects malformed or overly broad input");
        check(![browserAppend(browser, @[@"reddit.com"], 502)[@"ok"] boolValue] && ![browserAppend(browser, @[@"reddit.com"], 0)[@"ok"] boolValue], @"browser endpoint checks user ownership");
        NSDictionary *added = browserAppend(browser, @[@"reddit.com", @"news.reddit.com"], 501);
        check([added[@"saved"] boolValue] && [added[@"ok"] boolValue] && ![added[@"activeApplied"] boolValue] && !active, @"idle browser additions persist without starting a timer");
        check([browserAppend(browser, @[@"reddit.com"], 501)[@"alreadyPresent"] boolValue], @"duplicate browser additions are idempotent");
        NSDate *browserEnd = [NSDate dateWithTimeIntervalSinceNow:7200];
        block = [@{@"ActiveBlocklist":@[@"manual-only.com"], @"ActiveBlockAsWhitelist":@NO, @"BlockEndDate":browserEnd,
            @"ManualBlockEndDate":browserEnd, @"ScheduleManagedBlock":@YES} mutableCopy]; active = YES;
        added = browserAppend(browser, @[@"reddit.com"], 501);
        check([added[@"activeApplied"] boolValue] && [block[@"ActiveBlocklist"] containsObject:@"manual-only.com"], @"browser addition preserves manual-only active restrictions");
        check([block[@"BlockEndDate"] isEqual:browserEnd] && [block[@"ManualBlockEndDate"] isEqual:browserEnd], @"browser addition leaves timer provenance and end time intact");
        browser.failPersistence = YES;
        NSDictionary *browserBeforeFailure = [block copy];
        added = browserAppend(browser, @[@"persistence-failure.com"], 501);
        check(![added[@"saved"] boolValue] && [browserBeforeFailure isEqual:block], @"persistence failure leaves active enforcement untouched");
        browser.failPersistence = NO; failActiveUpdate = YES;
        added = browserAppend(browser, @[@"enforcement-failure.com"], 501);
        check([added[@"saved"] boolValue] && ![added[@"ok"] boolValue] && ![added[@"activeApplied"] boolValue], @"partial failure reports saved future policy separately from active enforcement");
        failActiveUpdate = NO;
        check([browserAppend(browser, @[@"enforcement-failure.com"], 501)[@"activeApplied"] boolValue], @"retry completes a previously saved addition");
        block[@"ActiveBlockAsWhitelist"] = @YES;
        check(![browserAppend(browser, @[@"allowlist-rejected.com"], 501)[@"saved"] boolValue], @"active allowlists reject browser additions without saving them");
        block[@"ActiveBlockAsWhitelist"] = @NO; legacy = YES;
        check(![browserAppend(browser, @[@"legacy-rejected.com"], 501)[@"ok"] boolValue], @"legacy blocks reject browser additions");
        legacy = NO; active = NO;
        dispatch_semaphore_t concurrent = dispatch_semaphore_create(0);
        for (NSString *domain in @[@"first-concurrent.com", @"second-concurrent.com"])
            [browser appendBlockedWebsites:@[domain] controllingUID:501 reply:^(NSDictionary *r, NSError *e) { check(!e, @"concurrent browser additions succeed"); dispatch_semaphore_signal(concurrent); }];
        waitFor(concurrent); waitFor(concurrent);
        check([status(browser)[@"blocklist"] containsObject:@"first-concurrent.com"] && [status(browser)[@"blocklist"] containsObject:@"second-concurrent.com"], @"concurrent browser additions do not lose entries");
        NSMutableDictionary *stalePolicy = [browserPolicy mutableCopy]; stalePolicy[@"expectedBlocklist"] = @[@"example.com"];
        __block NSError *staleError;
        dispatch_semaphore_t staleDone = dispatch_semaphore_create(0);
        [browser setSharedPolicy:stalePolicy controllingUID:501 friendPassword:@"" reply:^(NSError *e) { staleError=e; dispatch_semaphore_signal(staleDone); }]; waitFor(staleDone);
        check(staleError.code == 6 && [status(browser)[@"blocklist"] containsObject:@"reddit.com"], @"stale GUI commits cannot remove a browser addition");
        MemoryScheduleService *protectedBrowser = [MemoryScheduleService new];
        dispatch_semaphore_t protectionDone = dispatch_semaphore_create(0);
        [protectedBrowser setFriendPassword:@"browser-friend-password" policy:browserPolicy controllingUID:501 reply:^(NSError *e) { check(!e, @"browser protection fixture initializes"); dispatch_semaphore_signal(protectionDone); }]; waitFor(protectionDone);
        check([browserAppend(protectedBrowser, @[@"reddit.com"], 501)[@"ok"] boolValue] && protectedBrowser.friendProtectionEnabled, @"browser additions require no friend password and preserve protection");
        MemoryScheduleService *activeSetup = [MemoryScheduleService new]; active = YES;
        NSDictionary *activeBeforeSetup = [block copy];
        check(browserSetup(activeSetup, browserPolicy) == nil && [block isEqual:activeBeforeSetup] && !activeSetup.enabled, @"browser initialization preserves a running block and leaves scheduling disabled");
        active = NO;

        printf("%lu schedule service checks passed (mock enforcement; no firewall changes)\n", (unsigned long)checks);
    }
}
