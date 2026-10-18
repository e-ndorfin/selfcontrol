#import <Foundation/Foundation.h>
#import "SCWeeklySchedule.h"

static NSUInteger checks;
static void check(BOOL passed, NSString *message) {
    checks++;
    if (!passed) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSDate *date(NSString *text) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HH:mm Z";
    return [f dateFromString:text];
}
static NSArray *range(NSUInteger day, NSUInteger start, NSUInteger end) {
    return [SCWeeklySchedule slotsFromIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(day * 48 + start, end - start)]];
}
int main(void) {
    @autoreleasepool {
        NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        cal.timeZone = [NSTimeZone timeZoneWithName:@"America/Toronto"];
        NSArray *mon = range(0, 18, 34);
        check([SCWeeklySchedule slotAtDate:date(@"2026-10-12 09:00 -0400") calendar:cal] == 18, @"Monday starts the week");
        check([SCWeeklySchedule activeEndDateForSlots:mon atDate:date(@"2026-10-12 08:59 -0400") calendar:cal] == nil, @"start is exclusive before 09:00");
        check([[SCWeeklySchedule activeEndDateForSlots:mon atDate:date(@"2026-10-12 09:00 -0400") calendar:cal] isEqual:date(@"2026-10-12 17:00 -0400")], @"exact start activates through last contiguous cell");
        check([SCWeeklySchedule activeEndDateForSlots:mon atDate:date(@"2026-10-12 17:00 -0400") calendar:cal] == nil, @"exact end is open");
        check([SCWeeklySchedule activeEndDateForSlots:mon atDate:date(@"2026-10-13 09:15 -0400") calendar:cal] == nil, @"unselected days stay open");
        check([[SCWeeklySchedule nextStartDateForSlots:mon afterDate:date(@"2026-10-12 17:00 -0400") calendar:cal] isEqual:date(@"2026-10-19 09:00 -0400")], @"schedule repeats next week");
        check([[SCWeeklySchedule nextStartDateForSlots:mon afterDate:date(@"2026-10-12 08:15 -0400") calendar:cal] isEqual:date(@"2026-10-12 09:00 -0400")], @"find next boundary");
        check([SCWeeklySchedule nextStartDateForSlots:@[] afterDate:NSDate.date calendar:cal] == nil, @"empty schedule has no next start");
        check([[SCWeeklySchedule activeEndDateForSlots:@[@335, @0] atDate:date(@"2026-10-18 23:45 -0400") calendar:cal] isEqual:date(@"2026-10-19 00:30 -0400")], @"Sunday-to-Monday block remains contiguous");
        check([[SCWeeklySchedule activeEndDateForSlots:@[@18, @20] atDate:date(@"2026-10-12 09:15 -0400") calendar:cal] isEqual:date(@"2026-10-12 09:30 -0400")], @"gap splits separate blocks");
        check([[SCWeeklySchedule activeEndDateForSlots:range(6, 2, 4) atDate:date(@"2026-11-01 01:15 -0400") calendar:cal] isEqual:date(@"2026-11-01 02:00 -0500")], @"fall-back repeats the selected hour");
        check([[SCWeeklySchedule activeEndDateForSlots:range(6, 3, 7) atDate:date(@"2026-03-08 01:30 -0500") calendar:cal] isEqual:date(@"2026-03-08 03:30 -0400")], @"spring-forward skips nonexistent wall time");
        check([[SCWeeklySchedule nextStartDateForSlots:range(6, 4, 6) afterDate:date(@"2026-03-08 00:00 -0500") calendar:cal] isEqual:date(@"2026-03-15 02:00 -0400")], @"nonexistent-only period is skipped that week");
        cal.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Kathmandu"];
        check([[SCWeeklySchedule activeEndDateForSlots:@[@18] atDate:date(@"2026-10-12 09:15 +0545") calendar:cal] isEqual:date(@"2026-10-12 09:30 +0545")], @"quarter-hour-offset time zone uses local time");
        NSArray *all = [SCWeeklySchedule slotsFromIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 336)]];
        NSDate *now = NSDate.date;
        check(fabs([[SCWeeklySchedule activeEndDateForSlots:all atDate:now calendar:cal] timeIntervalSinceDate:now] - 86400) < 0.001, @"full week has a finite renewable end");
        check(![SCWeeklySchedule validSlots:@[@(-1)]] && ![SCWeeklySchedule validSlots:@[@336]] && ![SCWeeklySchedule validSlots:@[@1.5]], @"invalid cells rejected");
        check(![SCWeeklySchedule validSlots:@[@(NAN)]] && ![SCWeeklySchedule validSlots:@[@"18"]], @"nonfinite and nonnumeric cells rejected");
        NSMutableDictionary *settings = [NSMutableDictionary new];
        for (NSString *key in SCWeeklySchedule.blockSettingKeys) settings[key] = @0;
        NSMutableDictionary *config = [@{@"slots":@[@18, @18, @19], @"enabled":@YES, @"isAllowlist":@NO, @"blocklist":@[@"example.com"], @"blockSettings":settings} mutableCopy];
        NSError *error;
        check([[SCWeeklySchedule validatedConfiguration:config error:&error][@"slots"] isEqual:@[@18, @19]], @"duplicate slots canonicalized");
        config[@"blocklist"] = @[];
        check([SCWeeklySchedule validatedConfiguration:config error:&error] == nil, @"enabled blocklist cannot be empty");
        config[@"isAllowlist"] = @YES;
        check([SCWeeklySchedule validatedConfiguration:config error:&error] != nil, @"empty allowlist retains existing semantics");
        config[@"slots"] = @[];
        check([SCWeeklySchedule validatedConfiguration:config error:&error] == nil, @"enabled schedule cannot have no time");
        config[@"enabled"] = @NO;
        check([SCWeeklySchedule validatedConfiguration:config error:&error] != nil, @"disabled empty schedule is valid");
        config[@"blockSettings"] = @{};
        check([SCWeeklySchedule validatedConfiguration:config error:&error] == nil, @"missing enforcement settings rejected");
        check([SCWeeklySchedule validatedConfiguration:@"bad" error:&error] == nil, @"invalid configuration shape rejected");
        NSDictionary *baseline = @{@"blocklist":@[@"keep.com", @"remove.com"], @"isAllowlist":@NO, @"blockSettings":@{@"ClearCaches":@NO}};
        NSDictionary *local = @{@"blocklist":@[@"keep.com", @"local.com"], @"isAllowlist":@NO, @"blockSettings":@{@"ClearCaches":@NO}};
        NSDictionary *latest = @{@"blocklist":@[@"keep.com", @"remove.com", @"browser.com"], @"isAllowlist":@NO, @"blockSettings":@{@"ClearCaches":@YES}};
        NSDictionary *rebased = [SCWeeklySchedule sharedPolicy:local rebasedFrom:baseline onto:latest];
        check([rebased[@"blocklist"] isEqual:@[@"keep.com", @"browser.com", @"local.com"]], @"stale local additions and intentional removals retain concurrent browser sites");
        check([rebased[@"blockSettings"][@"ClearCaches"] boolValue], @"unchanged local options retain newer authoritative settings");
        check([SCWeeklySchedule validWebsiteDomains:@[@"xn--bcher-kva.de", @"news.bbc.co.uk"]], @"normalized browser domains validate");

        printf("%lu schedule model checks passed\n", (unsigned long)checks);
    }
}
