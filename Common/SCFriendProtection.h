#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
extern NSString * const SCFriendProtectionErrorDomain;
typedef NS_ENUM(NSInteger, SCFriendProtectionErrorCode) {
    SCFriendPasswordRequired = 401,
    SCFriendPasswordIncorrect = 402,
    SCFriendPasswordThrottled = 403,
    SCFriendProtectionUnavailable = 404
};

@interface SCFriendProtection : NSObject
+ (NSArray<NSString *> *)reductionReasonsFor:(NSDictionary *)proposed comparedTo:(NSDictionary *)saved;
+ (nullable NSDictionary *)recordForPassword:(NSString *)password error:(NSError * _Nullable * _Nullable)error;
+ (BOOL)validRecord:(id)record;
+ (BOOL)password:(NSString *)password matchesRecord:(NSDictionary *)record;
+ (NSError *)error:(SCFriendProtectionErrorCode)code message:(NSString *)message;
@end
NS_ASSUME_NONNULL_END
