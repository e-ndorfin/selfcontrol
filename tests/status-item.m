#import <Cocoa/Cocoa.h>
#import "SCStatusItemController.h"
#import "Common/SCWebsiteBreak.h"

@interface SCStatusItemController (IconChecks)
+ (NSImage *)statusImageAtURL:(NSURL *)url;
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static SCStatusItemState *State(SCStatusItemBlockPhase block, SCStatusItemBreakPhase websiteBreak, BOOL allowlist, BOOL busy, NSDate *now) {
    return [[SCStatusItemState alloc] initWithBlockPhase:block breakPhase:websiteBreak blockEndDate:[now dateByAddingTimeInterval:125] breakTransitionDate:[now dateByAddingTimeInterval:65] allowlist:allowlist busy:busy];
}
static void CheckMenu(SCStatusItemState *state, NSDate *now, BOOL canAddWebsites, NSString *context) {
    NSMenu *menu = [SCStatusItemController menuForState:state now:now];
    NSMutableArray *titles = [NSMutableArray new];
    for (NSMenuItem *item in menu.itemArray) {
        Check(!item.separatorItem, [context stringByAppendingString:@" has no separators"]);
        if (!item.hidden) [titles addObject:item.title];
    }
    NSArray *expected = canAddWebsites ? @[@"Open SelfControl", @"Add Websites…", @"Preferences…", @"Quit SelfControl"] : @[@"Open SelfControl", @"Preferences…", @"Quit SelfControl"];
    Check([titles isEqualToArray:expected], [NSString stringWithFormat:@"%@ visible actions are %@, got %@", context, expected, titles]);
    for (NSNumber *command in @[@(SCStatusItemCommandOpen), @(SCStatusItemCommandPreferences), @(SCStatusItemCommandQuit)]) {
        NSMenuItem *item = [menu itemWithTag:command.integerValue];
        Check(item.enabled && item.action != NULL, [context stringByAppendingString:@" navigation and quit remain available"]);
    }
    NSMenuItem *addWebsites = [menu itemWithTag:SCStatusItemCommandAddWebsites];
    Check(addWebsites.hidden == !canAddWebsites, [context stringByAppendingString:@" website addition visibility"]);
    Check(addWebsites.enabled == (canAddWebsites && !state.busy), [context stringByAppendingString:@" website addition availability"]);
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *bundlePath = NSProcessInfo.processInfo.environment[@"SC_STATUS_ICON_BUNDLE"];
        NSURL *iconURL = bundlePath ? [[NSBundle bundleWithPath:bundlePath] URLForResource:@"SelfControlStatusTemplate" withExtension:@"svg"] : [NSURL fileURLWithPath:@"SelfControlStatusTemplate.svg"];
        Check(iconURL && [NSFileManager.defaultManager fileExistsAtPath:iconURL.path], @"Skull asset exists in the requested resources");
        Check([[NSImage alloc] initWithContentsOfURL:iconURL] != nil, @"AppKit loads the skull SVG without using the fallback");
        for (NSNumber *fallback in @[@NO, @YES]) {
            NSImage *icon = [SCStatusItemController statusImageAtURL:fallback.boolValue ? nil : iconURL];
            Check(icon.isTemplate && NSEqualSizes(icon.size, NSMakeSize(18, 18)), @"Skull is an 18-point template");
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:180 pixelsHigh:180 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            [icon drawInRect:NSMakeRect(0, 0, 180, 180)];
            [NSGraphicsContext restoreGraphicsState];
            Check([bitmap colorAtX:0 y:0].alphaComponent < 0.01, @"Skull background stays transparent");
            Check([bitmap colorAtX:90 y:40].alphaComponent > 0.9, @"Skull has a solid forehead instead of a prohibition ring");
            Check([bitmap colorAtX:55 y:90].alphaComponent < 0.01 && [bitmap colorAtX:125 y:90].alphaComponent < 0.01, @"Both skull eye sockets are transparent");
            Check([bitmap colorAtX:90 y:90].alphaComponent > 0.9, @"Skull bridge remains solid between eye sockets");
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            [NSColor.whiteColor setFill];
            NSRectFillUsingOperation(NSMakeRect(0, 0, 180, 180), NSCompositingOperationDestinationOver);
            [NSGraphicsContext restoreGraphicsState];
            NSString *preview = fallback.boolValue ? @"build/status-skull-fallback.png" : @"build/status-skull-asset.png";
            Check([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:preview atomically:YES], @"Rendered skull preview saved");
        }
        NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
        CheckMenu(State(SCStatusItemBlockIdle, SCStatusItemBreakReady, NO, NO, now), now, NO, @"Idle scheduled block");
        CheckMenu(State(SCStatusItemBlockModern, SCStatusItemBreakReady, NO, NO, now), now, YES, @"Active blocklist");
        CheckMenu(State(SCStatusItemBlockModern, SCStatusItemBreakReady, YES, NO, now), now, NO, @"Active allowlist");
        CheckMenu(State(SCStatusItemBlockLegacy, SCStatusItemBreakReady, NO, NO, now), now, NO, @"Legacy block");
        CheckMenu(State(SCStatusItemBlockFinishing, SCStatusItemBreakReady, NO, NO, now), now, NO, @"Finishing block");
        CheckMenu(State(SCStatusItemBlockModern, SCStatusItemBreakReady, NO, YES, now), now, YES, @"Busy blocklist");
        for (NSInteger phase = SCStatusItemBreakUnavailable; phase <= SCStatusItemBreakCooldown; phase++) {
            CheckMenu(State(SCStatusItemBlockModern, phase, NO, NO, now), now, YES, @"Website break state");
        }
        Check(SCWebsiteBreakPhaseAtDate(YES, NO, NO, [now dateByAddingTimeInterval:10], [now dateByAddingTimeInterval:100], now) == SCWebsiteBreakActive, @"Shared timer policy prioritizes an active break");
        Check(SCWebsiteBreakPhaseAtDate(YES, NO, NO, now, [now dateByAddingTimeInterval:100], now) == SCWebsiteBreakCooldown, @"Shared break policy transitions at expiry");
        Check(SCWebsiteBreakPhaseAtDate(YES, NO, NO, now, now, now) == SCWebsiteBreakReady, @"Cooldown becomes available exactly at expiry");
        Check(SCWebsiteBreakPhaseAtDate(YES, YES, NO, now, now, now) == SCWebsiteBreakUnavailable, @"Shared policy excludes allowlists");
        NSLog(@"PASS: exact menu bar actions and website-break behavior");
    }
    return 0;
}
