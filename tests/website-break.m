#import "SCWebsiteBreak.h"
#import "SCSettings.h"
#import "SCDaemonBlockMethods.h"
#import "SCHelperToolUtilities.h"
#import "BlockManager.h"
#import "SCDaemon.h"
#import "LaunchctlHelper.h"
#import "HostFileBlockerSet.h"

static NSMutableDictionary *settings;
static NSArray *installed;
static BOOL failSync, failClear, failInstall;
static NSUInteger checks;
static void check(BOOL ok, NSString *message) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
@implementation SCSettings
+ (instancetype)sharedSettings { static id s; if (!s) s = [self new]; return s; }
- (id)valueForKey:(NSString *)key { return settings[key]; }
- (void)setValue:(id)value forKey:(NSString *)key { settings[key] = value; }
- (BOOL)boolForKey:(NSString *)key { return [settings[key] boolValue]; }
- (NSError *)syncSettingsAndWait:(NSInteger)seconds { return failSync ? [NSError errorWithDomain:@"Test" code:1 userInfo:nil] : nil; }
@end
@implementation SCBlockUtilities
+ (BOOL)anyBlockIsRunning { return [settings[@"BlockIsRunning"] boolValue]; }
+ (BOOL)modernBlockIsRunning { return self.anyBlockIsRunning; }
+ (BOOL)legacyBlockIsRunning { return NO; }
+ (BOOL)currentBlockIsExpired { return [settings[@"BlockEndDate"] timeIntervalSinceNow] <= 0; }
@end
@implementation BlockManager
- (BOOL)clearBlock { if (failClear) return NO; installed = nil; return YES; }
- (BOOL)blockIsActive { return installed != nil; }
@end
@implementation SCHelperToolUtilities
+ (void)installBlockRulesFromSettings {
    installed = failInstall ? nil : SCWebsiteBreakFilteredList(settings[@"ActiveBlocklist"], settings[@"WebsiteBreakDomain"], settings[@"WebsiteBreakUntil"], NSDate.date, [settings[@"ActiveBlockAsWhitelist"] boolValue]);
}
+ (void)clearOSDNSCache {}
+ (void)sendConfigurationChangedNotification {}
@end
@implementation SCDaemon
+ (instancetype)sharedDaemon { static id s; if (!s) s = [self new]; return s; }
- (void)resetInactivityTimer {}
@end
@implementation SCSentry
+ (void)addBreadcrumb:(NSString *)message category:(NSString *)category {}
+ (void)captureError:(NSError *)error {}
+ (void)captureMessage:(NSString *)message {}
@end
@implementation SCErr
+ (NSError *)errorWithCode:(NSInteger)code { return [NSError errorWithDomain:@"Test" code:code userInfo:nil]; }
@end
@implementation PacketFilter @end
@implementation HostFileBlockerSet @end
@implementation SCMiscUtilities @end
@implementation SCMigrationUtilities @end
@implementation LaunchctlHelper @end
static NSError *request(NSString *domain, uid_t uid) {
    __block NSError *result;
    [SCDaemonBlockMethods requestWebsiteBreak:domain controllingUID:uid reply:^(NSError *error) { result = error; }];
    return result;
}
static void reset(void) {
    failSync = failClear = failInstall = NO;
    settings = [@{@"ActiveBlocklist":@[@"example.com", @"www.example.com", @"video.example.com", @"other.com"],
        @"BlockIsRunning":@YES, @"BlockEndDate":[NSDate dateWithTimeIntervalSinceNow:3600], @"ActiveBlockAsWhitelist":@NO,
        @"BlockControllingUID":@501, @"WebsiteBreakDomain":@"", @"WebsiteBreakUntil":NSDate.distantPast,
        @"WebsiteBreakNextAvailable":NSDate.distantPast} mutableCopy];
    installed = settings[@"ActiveBlocklist"];
}
int main(void) {
    @autoreleasepool {
        reset();
        check(!request(@"www.example.com", 501), @"break granted without password or authorization data");
        check([installed isEqual:@[@"other.com"]], @"requested website and its subdomains temporarily unblocked");
        check([settings[@"ActiveBlocklist"] count] == 4, @"canonical blocklist unchanged");
        check(fabs([settings[@"WebsiteBreakUntil"] timeIntervalSinceNow] - 120) < 2, @"two-minute fixed duration");
        check(fabs([settings[@"WebsiteBreakNextAvailable"] timeIntervalSinceNow] - 1800) < 2, @"30-minute fixed cooldown");
        NSDate *until = settings[@"WebsiteBreakUntil"];
        check(request(@"other.com", 501) != nil, @"switching domains cannot bypass global cooldown");
        check([until isEqual:settings[@"WebsiteBreakUntil"]], @"repeated request cannot extend break");
        settings[@"WebsiteBreakUntil"] = NSDate.distantPast;
        [SCDaemonBlockMethods checkupBlock];
        check([installed isEqual:settings[@"ActiveBlocklist"]], @"daemon checkup restores website after expiration");
        check([settings[@"WebsiteBreakDomain"] isEqual:@""], @"pending break cleared after restore");
        check(request(@"example.com", 501) != nil, @"cooldown continues after reblocking");
        settings = [[NSPropertyListSerialization propertyListWithData:[NSPropertyListSerialization dataWithPropertyList:settings format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] options:NSPropertyListMutableContainers format:nil error:nil] mutableCopy];
        check(request(@"example.com", 501) != nil, @"persisted cooldown survives restart");
        settings[@"WebsiteBreakNextAvailable"] = NSDate.distantPast;
        check(!request(@"other.com", 501), @"next break granted after cooldown");
        reset(); check(request(@"example.com", 502) != nil, @"other users cannot request break");
        check(request(@"evil.com", 501) != nil, @"unlisted domains rejected");
        check(request(@"com", 501) != nil, @"top-level domains rejected");
        check(request(@"example.com:443", 501) != nil, @"port-specific input rejected");
        check(request(@"127.0.0.1", 501) != nil, @"IP input rejected");
        settings[@"ActiveBlockAsWhitelist"] = @YES;
        check(request(@"example.com", 501) != nil, @"allowlist blocks unchanged");
        reset(); settings[@"BlockIsRunning"] = @NO;
        check(request(@"example.com", 501) != nil, @"inactive blocks rejected");
        reset(); failSync = YES;
        check(request(@"example.com", 501) != nil, @"persistence failure rejects break");
        check([installed isEqual:settings[@"ActiveBlocklist"]], @"persistence failure leaves full block installed");
        reset(); failClear = YES;
        check(request(@"example.com", 501) != nil, @"network update failure rejects break");
        check([installed isEqual:settings[@"ActiveBlocklist"]], @"network update failure restores full block");
        reset(); check(!request(@"example.com", 501), @"prepare restore failure test");
        settings[@"WebsiteBreakUntil"] = NSDate.distantPast; failInstall = YES;
        [SCDaemonBlockMethods checkupBlock];
        check([settings[@"WebsiteBreakDomain"] length] > 0, @"failed restoration keeps retry marker");
        failInstall = NO; [SCDaemonBlockMethods checkupBlock];
        check([installed isEqual:settings[@"ActiveBlocklist"]], @"next checkup retries restoration successfully");
        check(!SCWebsiteBreakMatches(@"notexample.com", @"example.com"), @"domain boundary prevents unrelated exceptions");
        printf("%lu website-break checks passed (mock network rules)\n", (unsigned long)checks);
    }
}
