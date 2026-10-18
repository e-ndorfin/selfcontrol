#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "SCBrowserIntegration.h"
#import "SCXPCClient.h"
#import "SCConstants.h"

#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation SCXPCClient
- (void)getWeeklySchedule:(void (^)(NSDictionary *, NSError *))reply {
    NSString *mode = NSProcessInfo.processInfo.environment[@"SC_BROWSER_TEST_MODE"];
    if ([mode isEqual:@"missing"]) { reply(nil, [NSError errorWithDomain:@"Mock" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Helper unavailable"}]); return; }
    reply(@{@"browserIntegrationVersion":[mode isEqual:@"old"] ? @0 : @1}, nil);
}
- (void)appendBlockedWebsites:(NSArray *)domains reply:(void (^)(NSDictionary *, NSError *))reply {
    NSString *mode = NSProcessInfo.processInfo.environment[@"SC_BROWSER_TEST_MODE"];
    if ([mode isEqual:@"partial"]) {
        reply(@{@"saved":@YES, @"activeApplied":@NO}, [NSError errorWithDomain:@"Mock" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Active rules failed"}]);
        return;
    }
    reply(@{@"saved":@YES, @"activeApplied":@([mode isEqual:@"active"]), @"alreadyPresent":@([mode isEqual:@"duplicate"])}, nil);
}
- (void)installDaemon:(void (^)(NSError *))reply { reply(nil); }
- (void)refreshConnectionAndRun:(void (^)(void))reply { reply(); }
- (void)prepareBrowserIntegration:(NSDictionary *)policy reply:(void (^)(NSError *))reply { reply(nil); }
@end
@implementation SCConstants
+ (NSArray *)systemSoundNames { return @[]; }
+ (NSDictionary *)defaultUserDefaults { return @{}; }
@end
int main(int argc, char *argv[]) { return SCBrowserNativeMain(argc, argv); }
