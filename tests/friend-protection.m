#import <Foundation/Foundation.h>
#import "SCFriendProtection.h"
#import "SCWeeklySchedule.h"
static NSUInteger checks;
static void check(BOOL success, NSString *message) { checks++; if (!success) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
int main(void) { @autoreleasepool {
    NSMutableDictionary *settings = [NSMutableDictionary new];
    for (NSString *key in SCWeeklySchedule.blockSettingKeys) settings[key] = @YES;
    settings[@"AllowLocalNetworks"] = @NO;
    NSDictionary *base = @{@"enabled":@YES, @"slots":@[@18,@19], @"blocklist":@[@"example.com",@"news.example"], @"isAllowlist":@NO, @"blockSettings":settings};
    NSMutableDictionary *next = [base mutableCopy];
    check(![SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"unchanged configuration needs no approval");
    next[@"blocklist"] = @[@"example.com",@"news.example",@"video.example"];
    check(![SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"adding blocked sites is free");
    next[@"blocklist"] = @[@"example.com"];
    check([SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"removing a blocked site requires approval");
    next = [base mutableCopy]; next[@"slots"] = @[@18,@19,@20];
    check(![SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"additional time is free");
    next[@"slots"] = @[@18];
    check([SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"shortening scheduled time requires approval");
    next[@"slots"] = @[@20,@21,@22];
    check([SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"moving time requires approval even if total hours increase");
    next = [base mutableCopy]; next[@"enabled"] = @NO;
    check([SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"disabling a schedule requires approval");
    NSMutableDictionary *off = [base mutableCopy]; off[@"enabled"] = @NO;
    check(![SCFriendProtection reductionReasonsFor:base comparedTo:off].count,@"enabling saved time is free");
    next = [off mutableCopy]; next[@"slots"] = @[@21];
    check(![SCFriendProtection reductionReasonsFor:next comparedTo:off].count,@"editing unused times does not reduce active scheduling");
    next = [base mutableCopy]; next[@"isAllowlist"] = @YES;
    check([SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"mode changes cannot evade protection");
    NSDictionary *allowBase = [next copy]; next[@"blocklist"] = @[@"example.com"];
    check(![SCFriendProtection reductionReasonsFor:next comparedTo:allowBase].count,@"removing allowed sites increases restrictions");
    next[@"blocklist"] = @[@"example.com",@"news.example",@"video.example"];
    check([SCFriendProtection reductionReasonsFor:next comparedTo:allowBase].count,@"adding allowed sites reduces restrictions");
    for (NSString *key in @[@"EvaluateCommonSubdomains",@"IncludeLinkedDomains",@"ClearCaches"]) {
        next = [base mutableCopy]; NSMutableDictionary *weaker = [settings mutableCopy]; weaker[key] = @NO; next[@"blockSettings"] = weaker;
        check([SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"weakening coverage requires approval");
        check(![SCFriendProtection reductionReasonsFor:base comparedTo:next].count,@"strengthening coverage is free");
    }
    next = [base mutableCopy]; NSMutableDictionary *weaker = [settings mutableCopy]; weaker[@"AllowLocalNetworks"] = @YES; next[@"blockSettings"] = weaker;
    check([SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"allowing local access requires approval");
    check(![SCFriendProtection reductionReasonsFor:base comparedTo:next].count,@"blocking local access is free");
    next = [base mutableCopy]; NSMutableDictionary *cosmetic = [settings mutableCopy]; cosmetic[@"BlockSoundShouldPlay"] = @NO; cosmetic[@"EnableErrorReporting"] = @NO; next[@"blockSettings"] = cosmetic;
    check(![SCFriendProtection reductionReasonsFor:next comparedTo:base].count,@"sound and reporting are not blocking reductions");
    NSError *error;
    NSDictionary *record = [SCFriendProtection recordForPassword:@"test-friend-password" error:&error];
    NSDictionary *second = [SCFriendProtection recordForPassword:@"test-friend-password" error:&error];
    check(record && [SCFriendProtection validRecord:record],@"secure verifier created");
    check(![record[@"salt"] isEqual:second[@"salt"]] && ![record[@"hash"] isEqual:second[@"hash"]],@"unique random salts prevent identical verifiers");
    check([SCFriendProtection password:@"test-friend-password" matchesRecord:record],@"correct password verifies");
    check(![SCFriendProtection password:@"my-mac-admin-password" matchesRecord:record],@"Mac admin password is not a substitute");
    check(![SCFriendProtection password:@"" matchesRecord:record] && ![SCFriendProtection password:@"TEST-friend-password" matchesRecord:record],@"empty and case-changed passwords rejected");
    check([SCFriendProtection recordForPassword:@"short" error:&error] == nil,@"too-short password rejected");
    check(!record[@"password"],@"plaintext password is never stored");
    NSMutableDictionary *bad = [record mutableCopy]; bad[@"iterations"] = @1;
    check(![SCFriendProtection validRecord:bad] && ![SCFriendProtection password:@"test-friend-password" matchesRecord:bad],@"malformed verifier fails closed");
    bad = [record mutableCopy]; bad[@"hash"] = [NSData data];
    check(![SCFriendProtection validRecord:bad],@"truncated hash rejected");
    check(![SCFriendProtection validRecord:@"bad"],@"invalid storage shape rejected");
    NSDictionary *unicode = [SCFriendProtection recordForPassword:@"påssword-友達-123" error:&error];
    check([SCFriendProtection password:@"påssword-友達-123" matchesRecord:unicode],@"UTF-8 password verifies");
    printf("%lu friend-password and reduction-policy checks passed\n",(unsigned long)checks);
} }
