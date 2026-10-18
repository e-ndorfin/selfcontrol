#import "SCBrowserIntegration.h"
#import "SCBrowserMessage.h"
#import "SCXPCClient.h"
#import "SCWeeklySchedule.h"
#import <Security/Security.h>
#import "SCConstants.h"
#import <unistd.h>
#import <signal.h>
#import <sysexits.h>

static NSError *browserError(NSString *message) {
    return [NSError errorWithDomain:@"SelfControl.Browser" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
// Pump the main run loop because SCXPCClient connects on the main thread.
static BOOL waitForBrowserReply(BOOL (^finished)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    while (!finished() && deadline.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return finished();
}
NSDictionary *SCBrowserReadStatus(SCXPCClient *client, NSError **error) {
    __block BOOL done = NO;
    __block NSDictionary *status;
    __block NSError *failure;
    [client getWeeklySchedule:^(NSDictionary *result, NSError *replyError) {
        dispatch_async(dispatch_get_main_queue(), ^{ status = result; failure = replyError; done = YES; });
    }];
    if (!waitForBrowserReply(^BOOL { return done; })) failure = browserError(@"SelfControl did not respond. Open the app and try again.");
    if (error) *error = failure;
    return failure ? nil : status;
}
int SCBrowserNativeMain(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSError *error;
        NSDictionary *request;
        if (argc != 3 || ![@"chrome-extension://pklilielbinjmkllinkjahgnihbcbplp/" isEqualToString:@(argv[2])])
            error = browserError(@"This browser extension is not authorized to use the helper.");
        else request = SCBrowserReadMessage(STDIN_FILENO, &error);
        if (request && (![request[@"operation"] isEqual:@"append"] || ![SCWeeklySchedule validWebsiteDomains:request[@"domains"]]))
            error = browserError(@"Choose a public website with a valid domain name.");
        NSMutableDictionary *response = [@{@"ok":@NO, @"saved":@NO, @"activeApplied":@NO, @"alreadyPresent":@NO} mutableCopy];
        if (!error) {
            SCXPCClient *client = [SCXPCClient new];
            NSDictionary *status = SCBrowserReadStatus(client, &error);
            if (!error && [status[@"browserIntegrationVersion"] integerValue] != 1)
                error = browserError(@"Update the SelfControl helper by running browser integration setup.");
            if (!error) {
                __block BOOL done = NO;
                __block NSDictionary *result;
                __block NSError *failure;
                [client appendBlockedWebsites:request[@"domains"] reply:^(NSDictionary *replyResult, NSError *replyError) {
                    dispatch_async(dispatch_get_main_queue(), ^{ result = replyResult; failure = replyError; done = YES; });
                }];
                if (!waitForBrowserReply(^BOOL { return done; }))
                    error = browserError(@"Could not confirm the addition. Click again to safely retry.");
                else { [response addEntriesFromDictionary:result ?: @{}]; error = failure; }
            }
        }
        // C logical expressions can box as integers under the app's compiler
        // settings. Emit actual JSON booleans regardless of build configuration.
        for (NSString *key in @[@"saved", @"activeApplied", @"alreadyPresent"])
            response[key] = [response[key] boolValue] ? @YES : @NO;
        if (!error && ![response[@"saved"] boolValue]) error = browserError(@"SelfControl did not confirm that the website was saved. Click again to retry.");
        response[@"ok"] = error ? @NO : @YES;
        if (error) response[@"message"] = error.localizedDescription;
        NSError *writeError;
        BOOL replied = SCBrowserWriteMessage(STDOUT_FILENO, response, &writeError);
        return replied ? EX_OK : EX_IOERR;
    }
}
int SCBrowserStatusMain(void) {
    @autoreleasepool {
        NSError *error;
        NSDictionary *status = SCBrowserReadStatus([SCXPCClient new], &error);
        NSDictionary *result = error ? @{@"ok":@NO, @"message":error.localizedDescription} :
            @{@"ok":@YES, @"browserIntegrationVersion":status[@"browserIntegrationVersion"] ?: @0,
              @"configured":[NSNumber numberWithBool:status[@"slots"] != nil], @"ownedByCurrentUser":[NSNumber numberWithBool:[status[@"controllingUID"] unsignedIntValue] == getuid()],
              @"isAllowlist":status[@"isAllowlist"] ?: @NO, @"scheduleEnabled":status[@"enabled"] ?: @NO,
              @"friendProtectionEnabled":status[@"friendProtectionEnabled"] ?: @NO};
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
        return error ? EX_UNAVAILABLE : EX_OK;
    }
}
int SCBrowserSetupMain(void) {
    @autoreleasepool {
        if (getuid() == 0) { fprintf(stderr, "Run browser setup as your signed-in Mac user, without sudo.\n"); return EX_NOPERM; }
        SCXPCClient *client = [SCXPCClient new];
        __block BOOL done = NO;
        __block NSError *error;
        [client installDaemon:^(NSError *installError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (installError) { error = installError; done = YES; return; }
                [client refreshConnectionAndRun:^{
                    NSDictionary *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"org.eyebeam.SelfControl"].dictionaryRepresentation;
                    NSMutableDictionary *settings = [NSMutableDictionary new];
                    for (NSString *key in SCWeeklySchedule.blockSettingKeys)
                        settings[key] = defaults[key] ?: SCConstants.defaultUserDefaults[key];
                    NSDictionary *policy = @{@"blocklist":defaults[@"Blocklist"] ?: @[],
                        @"isAllowlist":defaults[@"BlockAsWhitelist"] ?: @NO, @"blockSettings":settings};
                    [client prepareBrowserIntegration:policy reply:^(NSError *replyError) {
                        dispatch_async(dispatch_get_main_queue(), ^{ error = replyError; done = YES; });
                    }];
                }];
            });
        }];
        while (!done) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        if (error) { fprintf(stderr, "Browser setup failed: %s\n", error.localizedDescription.UTF8String); return EX_SOFTWARE; }
        fprintf(stderr, "SelfControl browser integration is ready.\n");
        return EX_OK;
    }
}
