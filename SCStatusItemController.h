#import <Cocoa/Cocoa.h>
#import "SCStatusItemState.h"

typedef NS_ENUM(NSInteger, SCStatusItemCommand) {
    SCStatusItemCommandAddWebsites = 1, SCStatusItemCommandOpen, SCStatusItemCommandPreferences,
    SCStatusItemCommandQuit
};
@class SCStatusItemController;
@protocol SCStatusItemControllerDelegate <NSObject>
- (SCStatusItemState *)stateForStatusItemController:(SCStatusItemController *)controller;
- (void)statusItemController:(SCStatusItemController *)controller performCommand:(SCStatusItemCommand)command;
- (void)statusItemControllerWillHide:(SCStatusItemController *)controller;
- (void)statusItemControllerWillOpenMenu:(SCStatusItemController *)controller;
@end

@interface SCStatusItemController : NSObject <NSMenuDelegate>
@property (nonatomic, readonly, getter=isVisible) BOOL visible;
- (instancetype)initWithDelegate:(id<SCStatusItemControllerDelegate>)delegate;
- (void)refresh;
- (void)invalidate;
+ (NSMenu *)menuForState:(SCStatusItemState *)state now:(NSDate *)now;
@end
