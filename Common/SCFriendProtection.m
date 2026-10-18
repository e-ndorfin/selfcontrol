#import "SCFriendProtection.h"
#import "SCWeeklySchedule.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonKeyDerivation.h>
#import <CommonCrypto/CommonCryptor.h>

NSString * const SCFriendProtectionErrorDomain = @"SelfControl.FriendProtection";
static NSUInteger const SCPasswordIterations = 600000;

@implementation SCFriendProtection
+ (NSError *)error:(SCFriendProtectionErrorCode)code message:(NSString *)message {
    return [NSError errorWithDomain:SCFriendProtectionErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
+ (NSArray<NSString *> *)reductionReasonsFor:(NSDictionary *)proposed comparedTo:(NSDictionary *)saved {
    if (!saved) return @[];
    NSMutableArray *reasons = [NSMutableArray new];
    BOOL oldAllow = [saved[@"isAllowlist"] boolValue], newAllow = [proposed[@"isAllowlist"] boolValue];
    if (oldAllow != newAllow) [reasons addObject:@"Change between blocklist and allowlist modes"];
    else {
        NSSet *oldSites = [NSSet setWithArray:saved[@"blocklist"] ?: @[]];
        NSSet *newSites = [NSSet setWithArray:proposed[@"blocklist"] ?: @[]];
        if (!oldAllow && ![oldSites isSubsetOfSet:newSites]) [reasons addObject:@"Remove blocked websites"];
        if (oldAllow && ![newSites isSubsetOfSet:oldSites]) [reasons addObject:@"Allow additional websites"];
    }
    if ([saved[@"enabled"] boolValue]) {
        if (![proposed[@"enabled"] boolValue]) [reasons addObject:@"Disable scheduled blocking"];
        else {
            NSMutableIndexSet *removed = [[SCWeeklySchedule indexesFromSlots:saved[@"slots"] ?: @[]] mutableCopy];
            [removed removeIndexes:[SCWeeklySchedule indexesFromSlots:proposed[@"slots"] ?: @[]]];
            if (removed.count) [reasons addObject:@"Remove or move scheduled blocking time"];
        }
    }
    for (NSString *key in @[@"EvaluateCommonSubdomains", @"IncludeLinkedDomains", @"ClearCaches"]) {
        if ([saved[@"blockSettings"][key] boolValue] && ![proposed[@"blockSettings"][key] boolValue])
            [reasons addObject:@"Reduce domain coverage or cache clearing"];
    }
    if (![saved[@"blockSettings"][@"AllowLocalNetworks"] boolValue] && [proposed[@"blockSettings"][@"AllowLocalNetworks"] boolValue])
        [reasons addObject:@"Allow local-network access"];
    return reasons;
}
+ (NSData *)derivePassword:(NSString *)password salt:(NSData *)salt iterations:(NSUInteger)iterations {
    if (![password isKindOfClass:NSString.class]) return nil;
    NSData *bytes = [password dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes || bytes.length > 4096) return nil;
    NSMutableData *hash = [NSMutableData dataWithLength:32];
    int result = CCKeyDerivationPBKDF(kCCPBKDF2, bytes.bytes, bytes.length, salt.bytes, salt.length,
        kCCPRFHmacAlgSHA256, (unsigned int)iterations, hash.mutableBytes, hash.length);
    return result == kCCSuccess ? hash : nil;
}
+ (NSDictionary *)recordForPassword:(NSString *)password error:(NSError **)error {
    if (![password isKindOfClass:NSString.class] || password.length < 8 || password.length > 1024) {
        if (error) *error = [self error:SCFriendPasswordIncorrect message:@"Choose a friend-held password of at least 8 characters."];
        return nil;
    }
    NSMutableData *salt = [NSMutableData dataWithLength:16];
    if (SecRandomCopyBytes(kSecRandomDefault, salt.length, salt.mutableBytes) != errSecSuccess) {
        if (error) *error = [self error:SCFriendProtectionUnavailable message:@"Could not generate secure password storage. Protection was not changed."];
        return nil;
    }
    NSData *hash = [self derivePassword:password salt:salt iterations:SCPasswordIterations];
    if (!hash) {
        if (error) *error = [self error:SCFriendProtectionUnavailable message:@"Could not securely store the password. Protection was not changed."];
        return nil;
    }
    return @{@"version":@1, @"salt":salt, @"hash":hash, @"iterations":@(SCPasswordIterations)};
}
+ (BOOL)validRecord:(id)record {
    return [record isKindOfClass:NSDictionary.class] && [record[@"version"] isEqual:@1] &&
        [record[@"salt"] isKindOfClass:NSData.class] && [record[@"salt"] length] == 16 &&
        [record[@"hash"] isKindOfClass:NSData.class] && [record[@"hash"] length] == 32 &&
        [record[@"iterations"] isEqual:@(SCPasswordIterations)] &&
        (!record[@"failedAttempts"] || ([record[@"failedAttempts"] isKindOfClass:NSNumber.class] &&
            [record[@"failedAttempts"] integerValue] >= 0 && [record[@"failedAttempts"] integerValue] < 5)) &&
        (!record[@"retryAfter"] || [record[@"retryAfter"] isKindOfClass:NSDate.class]);
}
+ (BOOL)password:(NSString *)password matchesRecord:(NSDictionary *)record {
    if (![self validRecord:record]) return NO;
    NSData *candidate = [self derivePassword:password salt:record[@"salt"] iterations:[record[@"iterations"] unsignedIntegerValue]];
    if (candidate.length != 32) return NO;
    const uint8_t *a = candidate.bytes, *b = [record[@"hash"] bytes];
    volatile uint8_t difference = 0;
    for (NSUInteger i = 0; i < 32; i++) difference |= a[i] ^ b[i];
    return difference == 0;
}
@end
