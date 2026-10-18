#import <Cocoa/Cocoa.h>
#import "SCBlockUtilities.h"
#import "SCMiscUtilities.h"
#import "SCMigrationUtilities.h"
#import "SCErr.h"
@interface SCSentry : NSObject
+ (void)addBreadcrumb:(NSString *)message category:(NSString *)category;
+ (void)captureError:(NSError *)error;
+ (void)captureMessage:(NSString *)message;
@end
