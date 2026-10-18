#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Monday = 0; each day has 48 half-hour cells. Dates use local wall time.
@interface SCWeeklySchedule : NSObject
+ (NSDictionary *)sharedPolicy:(NSDictionary *)local rebasedFrom:(NSDictionary *)baseline onto:(NSDictionary *)current;
+ (BOOL)validWebsiteDomains:(id)domains;
+ (BOOL)validSlots:(id)slots;
+ (NSIndexSet *)indexesFromSlots:(NSArray<NSNumber *> *)slots;
+ (NSArray<NSNumber *> *)slotsFromIndexes:(NSIndexSet *)indexes;
+ (NSUInteger)slotAtDate:(NSDate *)date calendar:(NSCalendar *)calendar;
+ (nullable NSDate *)activeEndDateForSlots:(NSArray<NSNumber *> *)slots atDate:(NSDate *)date calendar:(NSCalendar *)calendar;
+ (nullable NSDate *)nextStartDateForSlots:(NSArray<NSNumber *> *)slots afterDate:(NSDate *)date calendar:(NSCalendar *)calendar;
+ (NSArray<NSString *> *)blockSettingKeys;
+ (nullable NSDictionary *)validatedConfiguration:(id)configuration error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
