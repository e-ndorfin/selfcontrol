#import "SCStatusItemController.h"

static NSString *SCMenuCountdown(NSDate *date, NSDate *now) {
    NSInteger seconds = MAX(0, (NSInteger)ceil([date timeIntervalSinceDate:now]));
    if (seconds >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600), (long)((seconds / 60) % 60), (long)(seconds % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

@interface SCStatusItemController ()
@property (nonatomic, weak) id<SCStatusItemControllerDelegate> delegate;
@property NSStatusItem *statusItem;
@property NSTimer *timer;
@end

@implementation SCStatusItemController
+ (NSImage *)statusImageAtURL:(NSURL *)url {
    NSImage *image = url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
    if (!image) {
        image = [NSImage imageWithSize:NSMakeSize(18, 18) flipped:YES drawingHandler:^BOOL(NSRect rect) {
            NSBezierPath *skull = [NSBezierPath bezierPath];
            [skull moveToPoint:NSMakePoint(9, 1)];
            [skull curveToPoint:NSMakePoint(2, 7.2) controlPoint1:NSMakePoint(4.5, 1) controlPoint2:NSMakePoint(2, 3.7)];
            [skull curveToPoint:NSMakePoint(2.6, 10.4) controlPoint1:NSMakePoint(2, 8.5) controlPoint2:NSMakePoint(2.2, 9.4)];
            [skull curveToPoint:NSMakePoint(3, 13) controlPoint1:NSMakePoint(1.9, 11.5) controlPoint2:NSMakePoint(2, 12.6)];
            [skull lineToPoint:NSMakePoint(5.2, 13.5)];
            [skull lineToPoint:NSMakePoint(5.5, 16)];
            [skull curveToPoint:NSMakePoint(7.2, 16) controlPoint1:NSMakePoint(5.6, 17.2) controlPoint2:NSMakePoint(7.1, 17.2)];
            [skull lineToPoint:NSMakePoint(7.4, 14.5)];
            [skull lineToPoint:NSMakePoint(8.1, 14.5)];
            [skull lineToPoint:NSMakePoint(8.3, 16)];
            [skull curveToPoint:NSMakePoint(9.7, 16) controlPoint1:NSMakePoint(8.4, 17.2) controlPoint2:NSMakePoint(9.6, 17.2)];
            [skull lineToPoint:NSMakePoint(9.9, 14.5)];
            [skull lineToPoint:NSMakePoint(10.6, 14.5)];
            [skull lineToPoint:NSMakePoint(10.8, 16)];
            [skull curveToPoint:NSMakePoint(12.5, 16) controlPoint1:NSMakePoint(10.9, 17.2) controlPoint2:NSMakePoint(12.4, 17.2)];
            [skull lineToPoint:NSMakePoint(12.8, 13.5)];
            [skull lineToPoint:NSMakePoint(15, 13)];
            [skull curveToPoint:NSMakePoint(15.4, 10.4) controlPoint1:NSMakePoint(16, 12.6) controlPoint2:NSMakePoint(16.1, 11.5)];
            [skull curveToPoint:NSMakePoint(16, 7.2) controlPoint1:NSMakePoint(15.8, 9.4) controlPoint2:NSMakePoint(16, 8.5)];
            [skull curveToPoint:NSMakePoint(9, 1) controlPoint1:NSMakePoint(16, 3.7) controlPoint2:NSMakePoint(13.5, 1)];
            [skull closePath];
            [skull appendBezierPathWithOvalInRect:NSMakeRect(3.4, 7.2, 4.4, 3.6)];
            [skull appendBezierPathWithOvalInRect:NSMakeRect(10.2, 7.2, 4.4, 3.6)];
            [skull moveToPoint:NSMakePoint(9, 10.4)];
            [skull lineToPoint:NSMakePoint(8, 12.1)];
            [skull curveToPoint:NSMakePoint(9, 12.7) controlPoint1:NSMakePoint(7.7, 12.8) controlPoint2:NSMakePoint(8.2, 13.2)];
            [skull curveToPoint:NSMakePoint(10, 12.1) controlPoint1:NSMakePoint(9.8, 13.2) controlPoint2:NSMakePoint(10.3, 12.8)];
            [skull closePath];
            skull.windingRule = NSWindingRuleEvenOdd;
            [NSColor.blackColor setFill];
            [skull fill];
            return YES;
        }];
    }
    image.size = NSMakeSize(18, 18);
    image.template = YES;
    return image;
}
- (instancetype)initWithDelegate:(id<SCStatusItemControllerDelegate>)delegate {
    if ((self = [super init])) {
        _delegate = delegate;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:NSUserDefaultsDidChangeNotification object:nil];
        __weak SCStatusItemController *weakSelf = self;
        _timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [weakSelf refresh]; }];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
        [self refresh];
    }
    return self;
}
- (BOOL)isVisible { return self.statusItem != nil; }
- (void)invalidate {
    [self.timer invalidate]; self.timer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (self.statusItem) [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
    self.statusItem = nil;
}
- (void)dealloc { [self invalidate]; }
+ (NSMenu *)menuForState:(SCStatusItemState *)state now:(NSDate *)now {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    BOOL modern = state.blockPhase == SCStatusItemBlockModern;
    void (^row)(NSString *, NSInteger, BOOL, BOOL) = ^(NSString *title, NSInteger command, BOOL enabled, BOOL hidden) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:command ? @selector(performMenuCommand:) : NULL keyEquivalent:@""];
        item.tag = command; item.enabled = enabled; item.hidden = hidden; [menu addItem:item];
    };
    row(NSLocalizedStringFromTable(@"Open SelfControl", @"StatusItem", @"menu bar open action"), SCStatusItemCommandOpen, YES, NO);
    row(NSLocalizedStringFromTable(@"Add Websites…", @"StatusItem", @"menu bar add websites action"), SCStatusItemCommandAddWebsites, modern && !state.busy && !state.allowlist, !modern || state.allowlist);
    row(NSLocalizedStringFromTable(@"Preferences…", @"StatusItem", @"menu bar preferences action"), SCStatusItemCommandPreferences, YES, NO);
    row(NSLocalizedStringFromTable(@"Quit SelfControl", @"StatusItem", @"menu bar quit action"), SCStatusItemCommandQuit, YES, NO);
    return menu;
}
- (void)refresh {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; }); return; }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:@"ShowMenuBarItem"]) {
        if (self.statusItem) {
            [self.delegate statusItemControllerWillHide:self];
            [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem]; self.statusItem = nil;
        }
        return;
    }
    if (!self.statusItem) {
        self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
        NSURL *iconURL = [[NSBundle bundleForClass:self.class] URLForResource:@"SelfControlStatusTemplate" withExtension:@"svg"];
        self.statusItem.button.image = [self.class statusImageAtURL:iconURL];
        self.statusItem.button.toolTip = @"SelfControl";
    }
    SCStatusItemState *state = [self.delegate stateForStatusItemController:self];
    if (!state) return;
    NSMenu *projection = [self.class menuForState:state now:NSDate.date];
    if (!self.statusItem.menu) {
        projection.delegate = self; self.statusItem.menu = projection;
        for (NSMenuItem *item in projection.itemArray) if (item.tag) item.target = self;
    } else {
        [projection.itemArray enumerateObjectsUsingBlock:^(NSMenuItem *item, NSUInteger index, BOOL *stop) {
            NSMenuItem *existing = [self.statusItem.menu itemAtIndex:(NSInteger)index];
            existing.title = item.title; existing.enabled = item.enabled; existing.hidden = item.hidden;
        }];
    }
    self.statusItem.button.title = [defaults boolForKey:@"ShowMenuBarCountdown"] && state.blockPhase != SCStatusItemBlockIdle ? [@" " stringByAppendingString:state.blockPhase == SCStatusItemBlockFinishing ? NSLocalizedStringFromTable(@"Finishing…", @"StatusItem", @"menu bar finishing countdown") : SCMenuCountdown(state.blockEndDate, NSDate.date)] : @"";
}
- (void)menuWillOpen:(NSMenu *)menu { [self.delegate statusItemControllerWillOpenMenu:self]; [self refresh]; }
- (void)performMenuCommand:(NSMenuItem *)sender { [self.delegate statusItemController:self performCommand:sender.tag]; }
@end
