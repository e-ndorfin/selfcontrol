#import <Foundation/Foundation.h>
@interface SCBlockUtilities : NSObject
+ (BOOL)anyBlockIsRunning;
+ (BOOL)currentBlockIsExpired;
+ (BOOL)legacyBlockIsRunning;
@end
@interface SCSettings : NSObject
+ (instancetype)sharedSettings;
- (id)valueForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (void)setValue:(id)value forKey:(NSString *)key;
- (NSError *)syncSettingsAndWait:(NSTimeInterval)timeout;
@end
@interface SCMiscUtilities : NSObject
+ (NSArray *)cleanBlocklist:(NSArray *)entries;
@end
@interface SCHelperToolUtilities : NSObject
+ (void)sendConfigurationChangedNotification;
@end
