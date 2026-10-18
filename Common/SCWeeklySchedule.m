#import "SCWeeklySchedule.h"
#import <math.h>

@implementation SCWeeklySchedule
+ (NSDictionary *)sharedPolicy:(NSDictionary *)local rebasedFrom:(NSDictionary *)baseline onto:(NSDictionary *)current {
    NSMutableDictionary *result = [NSMutableDictionary new];
    BOOL changedMode = baseline && ![local[@"isAllowlist"] isEqual:baseline[@"isAllowlist"]];
    if (changedMode) {
        result[@"isAllowlist"] = local[@"isAllowlist"];
        result[@"blocklist"] = local[@"blocklist"];
    } else {
        result[@"isAllowlist"] = current[@"isAllowlist"] ?: local[@"isAllowlist"];
        NSMutableOrderedSet *sites = [NSMutableOrderedSet orderedSetWithArray:current[@"blocklist"] ?: @[]];
        for (NSString *entry in baseline[@"blocklist"] ?: @[])
            if (![local[@"blocklist"] containsObject:entry]) [sites removeObject:entry];
        for (NSString *entry in local[@"blocklist"] ?: @[])
            if (![baseline[@"blocklist"] containsObject:entry]) [sites addObject:entry];
        result[@"blocklist"] = sites.array;
    }
    NSMutableDictionary *settings = [current[@"blockSettings"] mutableCopy] ?: [NSMutableDictionary new];
    [local[@"blockSettings"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        if (!baseline || ![value isEqual:baseline[@"blockSettings"][key]]) settings[key] = value;
    }];
    result[@"blockSettings"] = settings;
    return result;
}
+ (BOOL)validWebsiteDomains:(id)domains {
    if (![domains isKindOfClass:NSArray.class] || ![domains count] || [domains count] > 2) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-."] invertedSet];
    for (id value in domains) {
        if (![value isKindOfClass:NSString.class]) return NO;
        NSString *domain = value;
        if (domain.length > 253 || [domain rangeOfCharacterFromSet:invalid].location != NSNotFound) return NO;
        NSArray *labels = [domain componentsSeparatedByString:@"."];
        if (labels.count < 2 || [domain hasSuffix:@".local"] || [domain hasSuffix:@".localhost"]) return NO;
        for (NSString *label in labels)
            if (!label.length || label.length > 63 || [label hasPrefix:@"-"] || [label hasSuffix:@"-"]) return NO;
        NSString *last = labels.lastObject;
        if ([last rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound) return NO;
    }
    return YES;
}
+ (BOOL)validSlots:(id)slots {
    if (![slots isKindOfClass:NSArray.class] || [slots count] > 336) return NO;
    for (id slot in slots) {
        if (![slot isKindOfClass:NSNumber.class] || !isfinite([slot doubleValue]) ||
            [slot doubleValue] != [slot integerValue] || [slot integerValue] < 0 || [slot integerValue] >= 336) return NO;
    }
    return YES;
}
+ (NSIndexSet *)indexesFromSlots:(NSArray<NSNumber *> *)slots {
    NSMutableIndexSet *indexes = [NSMutableIndexSet new];
    if ([self validSlots:slots]) for (NSNumber *slot in slots) [indexes addIndex:slot.unsignedIntegerValue];
    return indexes;
}
+ (NSArray<NSNumber *> *)slotsFromIndexes:(NSIndexSet *)indexes {
    NSMutableArray *slots = [NSMutableArray new];
    [indexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) { [slots addObject:@(idx)]; }];
    return slots;
}
+ (NSUInteger)slotAtDate:(NSDate *)date calendar:(NSCalendar *)calendar {
    NSDateComponents *c = [calendar components:NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute fromDate:date];
    return ((c.weekday + 5) % 7) * 48 + c.hour * 2 + c.minute / 30;
}
+ (NSDate *)nextBoundaryAfterDate:(NSDate *)date calendar:(NSCalendar *)calendar {
    NSDateComponents *c = [calendar components:NSCalendarUnitMinute | NSCalendarUnitSecond | NSCalendarUnitNanosecond fromDate:date];
    NSTimeInterval seconds = 1800 - ((c.minute % 30) * 60 + c.second + c.nanosecond / 1e9);
    return [date dateByAddingTimeInterval:MAX(seconds, 0.001)];
}
+ (NSDate *)activeEndDateForSlots:(NSArray<NSNumber *> *)slots atDate:(NSDate *)date calendar:(NSCalendar *)calendar {
    NSIndexSet *indexes = [self indexesFromSlots:slots];
    if (![indexes containsIndex:[self slotAtDate:date calendar:calendar]]) return nil;
    // A fully selected week is renewed by the daemon a day at a time.
    if (indexes.count == 336) return [date dateByAddingTimeInterval:86400];
    NSDate *cursor = [self nextBoundaryAfterDate:date calendar:calendar];
    for (NSUInteger i = 0; i < 400; i++) {
        if (![indexes containsIndex:[self slotAtDate:cursor calendar:calendar]]) return cursor;
        cursor = [self nextBoundaryAfterDate:cursor calendar:calendar];
    }
    return nil;
}
+ (NSDate *)nextStartDateForSlots:(NSArray<NSNumber *> *)slots afterDate:(NSDate *)date calendar:(NSCalendar *)calendar {
    NSIndexSet *indexes = [self indexesFromSlots:slots];
    if (!indexes.count) return nil;
    if ([indexes containsIndex:[self slotAtDate:date calendar:calendar]]) return date;
    NSDate *cursor = [self nextBoundaryAfterDate:date calendar:calendar];
    for (NSUInteger i = 0; i < 400; i++) {
        if ([indexes containsIndex:[self slotAtDate:cursor calendar:calendar]]) return cursor;
        cursor = [self nextBoundaryAfterDate:cursor calendar:calendar];
    }
    return nil;
}
+ (NSArray<NSString *> *)blockSettingKeys {
    return @[@"ClearCaches", @"AllowLocalNetworks", @"EvaluateCommonSubdomains", @"IncludeLinkedDomains", @"BlockSoundShouldPlay", @"BlockSound", @"EnableErrorReporting"];
}
+ (NSDictionary *)validatedConfiguration:(id)configuration error:(NSError **)error {
    BOOL valid = [configuration isKindOfClass:NSDictionary.class];
    NSDictionary *c = valid ? configuration : @{};
    valid = valid && [self validSlots:c[@"slots"]] && [c[@"enabled"] isKindOfClass:NSNumber.class] &&
        [c[@"isAllowlist"] isKindOfClass:NSNumber.class] && [c[@"blocklist"] isKindOfClass:NSArray.class] &&
        [c[@"blocklist"] count] <= 10000 && [c[@"blockSettings"] isKindOfClass:NSDictionary.class];
    if (valid) {
        for (id entry in c[@"blocklist"]) {
            if (![entry isKindOfClass:NSString.class] || ![entry length] || [entry length] > 4096) { valid = NO; break; }
        }
        for (NSString *key in [self blockSettingKeys]) {
            if (![c[@"blockSettings"][key] isKindOfClass:NSNumber.class]) valid = NO;
        }
        NSNumber *sound = c[@"blockSettings"][@"BlockSound"];
        if (sound.integerValue < 0 || sound.integerValue > 13) valid = NO;
        if ([c[@"enabled"] boolValue] && (![c[@"slots"] count] || (![c[@"isAllowlist"] boolValue] && ![c[@"blocklist"] count]))) valid = NO;
    }
    if (!valid) {
        if (error) *error = [NSError errorWithDomain:@"SelfControl.Schedule" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Choose at least one time period and add websites before enabling your schedule."}];
        return nil;
    }
    NSMutableDictionary *settings = [NSMutableDictionary new];
    for (NSString *key in [self blockSettingKeys]) settings[key] = c[@"blockSettings"][key];
    return @{@"slots":[self slotsFromIndexes:[self indexesFromSlots:c[@"slots"]]], @"enabled":@([c[@"enabled"] boolValue]),
             @"blocklist":[c[@"blocklist"] copy], @"isAllowlist":@([c[@"isAllowlist"] boolValue]), @"blockSettings":settings};
}
@end
