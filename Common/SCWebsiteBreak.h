#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, SCWebsiteBreakPhase) {
    SCWebsiteBreakUnavailable, SCWebsiteBreakReady, SCWebsiteBreakPending,
    SCWebsiteBreakActive, SCWebsiteBreakCooldown
};

static inline SCWebsiteBreakPhase SCWebsiteBreakPhaseAtDate(BOOL modern, BOOL allowlist, BOOL pending, NSDate *until, NSDate *nextAvailable, NSDate *now) {
    if (!modern || allowlist) return SCWebsiteBreakUnavailable;
    if (pending) return SCWebsiteBreakPending;
    if ([until timeIntervalSinceDate:now] > 0) return SCWebsiteBreakActive;
    if ([nextAvailable timeIntervalSinceDate:now] > 0) return SCWebsiteBreakCooldown;
    return SCWebsiteBreakReady;
}

// The saved list remains authoritative. Only rule generation uses this temporary view.
static inline NSString *SCWebsiteBreakDomain(id value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *domain = [value lowercaseString];
    if ([domain hasPrefix:@"www."]) domain = [domain substringFromIndex:4];
    if (domain.length > 253 || ![[NSPredicate predicateWithFormat:@"SELF MATCHES %@",
        @"([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?"] evaluateWithObject:domain]) return nil;
    if ([domain hasSuffix:@".local"] || [domain hasSuffix:@".localhost"]) return nil;
    return domain;
}

static inline BOOL SCWebsiteBreakMatches(NSString *entry, NSString *domain) {
    NSString *host = entry.lowercaseString;
    return [host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]];
}

static inline NSArray<NSString *> *SCWebsiteBreakFilteredList(NSArray<NSString *> *sites, NSString *domain, NSDate *until, NSDate *now, BOOL allowlist) {
    if (allowlist || !SCWebsiteBreakDomain(domain) || ![until isKindOfClass:NSDate.class] || [until compare:now] != NSOrderedDescending) return sites;
    NSMutableArray *filtered = [NSMutableArray new];
    for (NSString *site in sites) if (!SCWebsiteBreakMatches(site, domain)) [filtered addObject:site];
    return filtered;
}
