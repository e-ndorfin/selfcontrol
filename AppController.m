//
//  AppController.m
//  SelfControl
//
//  Created by Charlie Stigler on 1/29/09.
//  Copyright 2009 Eyebeam.

// This file is part of SelfControl.
//
// SelfControl is free software:  you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

#import "AppController.h"
#import "MASPreferencesWindowController.h"
#import "PreferencesGeneralViewController.h"
#import "PreferencesAdvancedViewController.h"
#import "SCTimeIntervalFormatter.h"
#import <LetsMove/PFMoveApplication.h>
#import "SCSettings.h"
#import <ServiceManagement/ServiceManagement.h>
#import "SCXPCClient.h"
#import "SCBlockFileReaderWriter.h"
#import "SCUIUtilities.h"
#import <TransformerKit/NSValueTransformer+TransformerKit.h>
#import "SCWeeklyScheduleViewController.h"
#import "SCWebsiteBreak.h"
#import "SCStatusItemController.h"

@interface AppController () <SCStatusItemControllerDelegate>

@property (atomic, strong, readwrite) SCXPCClient* xpc;
@property SCWeeklyScheduleViewController *scheduleController;
@property SCStatusItemController *statusItemController;

@end

@implementation AppController {
	NSWindowController* getStartedWindowController;
}

@synthesize addingBlock;

- (AppController*) init {
	if(self = [super init]) {

		defaults_ = [NSUserDefaults standardUserDefaults];
		[defaults_ registerDefaults: SCConstants.defaultUserDefaults];

		self.addingBlock = false;

		// refreshUILock_ is a lock that prevents a race condition by making the refreshUserInterface
		// method alter the blockIsOn variable atomically (will no longer be necessary once we can
		// use properties).
		refreshUILock_ = [[NSLock alloc] init];
	}

	return self;
}

- (IBAction)updateTimeSliderDisplay:(id)sender {
    NSInteger numMinutes = [defaults_ integerForKey: @"BlockDuration"];

    // if the duration is larger than we can display on our slider
    // chop it down to our max display value so the user doesn't
    // accidentally start a much longer block than intended
    if (numMinutes > blockDurationSlider_.maxDuration) {
        [self setDefaultsBlockDurationOnMainThread: @(floor(blockDurationSlider_.maxDuration))];
        numMinutes = [defaults_ integerForKey: @"BlockDuration"];
    }

    blockSliderTimeDisplayLabel_.stringValue = blockDurationSlider_.durationDescription;

	[submitButton_ setEnabled: (numMinutes > 0) && ([[defaults_ arrayForKey: @"Blocklist"] count] > 0)];
}

- (IBAction)addBlock:(id)sender {
    [self.scheduleController refreshSharedPolicyFromDaemonWithCompletion:^(NSError *error) {
        if (error) { [SCUIUtilities presentError:error]; return; }
        [self startManualBlockAfterPolicyRefresh:sender];
    }];
}
- (void)startManualBlockAfterPolicyRefresh:(id)sender {
    if ([SCUIUtilities blockIsRunning]) {
		// This method shouldn't be getting called, a block is on so the Start button should be disabled.
        NSError* err = [SCErr errorWithCode: 104];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
		return;
	}
	if (([[defaults_ arrayForKey: @"Blocklist"] count] == 0) && ![defaults_ boolForKey: @"BlockAsWhitelist"]) {
		// Since the Start button should be disabled when the blocklist has no entries (and it's not an allowlist)
		// this should definitely not be happening.  Exit.

        NSError* err = [SCErr errorWithCode: 100];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];

		return;
	}

	if([defaults_ boolForKey: @"VerifyInternetConnection"] && ![SCUIUtilities networkConnectionIsAvailable]) {
		NSAlert* networkUnavailableAlert = [[NSAlert alloc] init];
		[networkUnavailableAlert setMessageText: NSLocalizedString(@"No network connection detected", "No network connection detected message")];
		[networkUnavailableAlert setInformativeText:NSLocalizedString(@"A block cannot be started without a working network connection.  You can override this setting in Preferences.", @"Message when network connection is unavailable")];
		[networkUnavailableAlert addButtonWithTitle: NSLocalizedString(@"OK", "OK button")];
        [networkUnavailableAlert runModal];
		return;
	}

    // cancel if we pop up a warning about the super long block, and the user decides to cancel
    if (![self showLongBlockWarningsIfNecessary]) {
        return;
    }

	[timerWindowController_ resetStrikes];

	[self.scheduleController syncSharedPolicyIfNeededWithCompletion:^(BOOL approved) {
        if (approved) [NSThread detachNewThreadSelector:@selector(installBlock) toTarget:self withObject:nil];
    }];
}

// returns YES if we should continue with the block, NO if we should cancel it
- (BOOL)showLongBlockWarningsIfNecessary {
    // all UI stuff MUST be done on the main thread
    if (![NSThread isMainThread]) {
        __block BOOL retVal = NO;
        dispatch_sync(dispatch_get_main_queue(), ^{
            retVal = [self showLongBlockWarningsIfNecessary];
        });
        return retVal;
    }
    
    NSString* LONG_BLOCK_SUPPRESSION_KEY = @"SuppressLongBlockWarning";
    int LONG_BLOCK_THRESHOLD_MINS = 2880; // 2 days
    int FIRST_TIME_LONG_BLOCK_THRESHOLD_MINS = 480; // 8 hours

    BOOL isFirstBlock = ![defaults_ boolForKey: @"FirstBlockStarted"];
    int blockDuration = [[self->defaults_ valueForKey: @"BlockDuration"] intValue];

    BOOL showLongBlockWarning = blockDuration >= LONG_BLOCK_THRESHOLD_MINS || (isFirstBlock && blockDuration >= FIRST_TIME_LONG_BLOCK_THRESHOLD_MINS);
    if (!showLongBlockWarning) return YES;

    // if they don't want warnings, they don't get warnings. their funeral 💀
    if ([self->defaults_ boolForKey: LONG_BLOCK_SUPPRESSION_KEY]) {
        return YES;
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"That's a long block!", "Long block warning title");
    alert.informativeText = [NSString stringWithFormat: NSLocalizedString(@"Remember that once you start the block, you can't turn it back off until the timer expires in %@ - even if you accidentally blocked a site you need. Consider starting a shorter block first, to test your list and make sure everything's working properly.", @"Long block warning message"), [SCDurationSlider timeSliderDisplayStringFromNumberOfMinutes: blockDuration]];
    [alert addButtonWithTitle: NSLocalizedString(@"Cancel", @"Button to cancel a long block")];
    [alert addButtonWithTitle: NSLocalizedString(@"Start Block Anyway", "Button to start a long block despite warnings")];
    alert.showsSuppressionButton = YES;

    NSModalResponse modalResponse = [alert runModal];
    if (alert.suppressionButton.state == NSControlStateValueOn) {
        // no more warnings, they say
        [self->defaults_ setBool: YES forKey: LONG_BLOCK_SUPPRESSION_KEY];
    }
    if (modalResponse == NSAlertFirstButtonReturn) {
        return NO;
    }
    
    return YES;
}


- (void)refreshUserInterface {
    // UI updates are for the main thread only!
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self refreshUserInterface];
        });
        return;
    }

	if(![refreshUILock_ tryLock]) {
		// already refreshing the UI, no need to wait and do it again
		return;
	}

	BOOL blockWasOn = blockIsOn;
	blockIsOn = [SCUIUtilities blockIsRunning];

	if(blockIsOn) { // block is on
		[blockDurationSlider_ setEnabled:NO];
		[submitButton_ setEnabled:NO];
		[editBlocklistButton_ setEnabled:![SCBlockUtilities legacyBlockIsRunning]];
		if(!blockWasOn) { // if we just switched states to on...
			[self closeTimerWindow];
			[self showTimerWindow];
			[self closeDomainList];
            
            // apparently, a block is running, so make sure FirstBlockStarted is true
            [defaults_ setBool: YES forKey: @"FirstBlockStarted"];
		}
    } else { // block is off
		if(blockWasOn) { // if we just switched states to off...
			[timerWindowController_ blockEnded];

			// Makes sure the domain list will refresh when it comes back
			[self closeDomainList];

			NSWindow* mainWindow = [NSApp mainWindow];
			// We don't necessarily want the initial window to be key and front,
			// but no other message seems to show it properly.
			[initialWindow_ makeKeyAndOrderFront: self];
			// So we work around it and make key and front whatever was the main window
			[mainWindow makeKeyAndOrderFront: self];
            
            // make sure the dock badge is cleared
            [[NSApp dockTile] setBadgeLabel: nil];

            // send a notification letting the user know the block ended
            // TODO: make this sent from a background process so it shows if app is closed
            // (but we can't send it from the selfcontrold process, because it's running as root)
            NSUserNotificationCenter* userNoteCenter = [NSUserNotificationCenter defaultUserNotificationCenter];
            NSUserNotification* endedNote = [NSUserNotification new];
            endedNote.title = @"Your SelfControl block has ended!";
            endedNote.informativeText = @"All sites are now accessible.";
            [userNoteCenter deliverNotification: endedNote];

			[self closeTimerWindow];
		}

		[self updateTimeSliderDisplay: blockDurationSlider_];

		if([defaults_ integerForKey: @"BlockDuration"] != 0 &&
           ([[defaults_ arrayForKey: @"Blocklist"] count] != 0 || [defaults_ boolForKey: @"BlockAsWhitelist"]) &&
           !self.addingBlock) {
			[submitButton_ setEnabled: YES];
		} else {
			[submitButton_ setEnabled: NO];
		}

		// If we're adding a block, we want buttons disabled.
        if(!self.addingBlock) {
			[blockDurationSlider_ setEnabled: YES];
			[editBlocklistButton_ setEnabled: YES];
			[submitButton_ setTitle: NSLocalizedString(@"Start Block", @"Start button")];
		} else {
			[blockDurationSlider_ setEnabled: NO];
			[editBlocklistButton_ setEnabled: NO];
			[submitButton_ setTitle: NSLocalizedString(@"Starting Block", @"Starting Block button")];
		}

		// if block's off, and we haven't shown it yet, show the first-time modal
		if (![defaults_ boolForKey: @"GetStartedShown"]) {
			[defaults_ setBool: YES forKey: @"GetStartedShown"];
			[self showGetStartedWindow: self];
		}
	}

    // finally: if the helper tool marked that it detected tampering, make sure
    // we follow through and set the cheater wallpaper (helper tool can't do it itself)
    if ([settings_ boolForKey: @"TamperingDetected"]) {
        NSURL* cheaterBackgroundURL = [[NSBundle mainBundle] URLForResource: @"cheater-background" withExtension: @"png"];
            NSArray<NSScreen *>* screens = [NSScreen screens];
        for (NSScreen* screen in screens) {
            NSError* err;
            [[NSWorkspace sharedWorkspace] setDesktopImageURL: cheaterBackgroundURL
                                                    forScreen: screen
                                                      options: @{}
                                                        error: &err];
        }
        [settings_ setValue: @NO forKey: @"TamperingDetected"];
    }
    
    // Display "blocklist" or "allowlist" as appropriate
    NSString* listType = [defaults_ boolForKey: @"BlockAsWhitelist"] ? @"Allowlist" : @"Blocklist";
    NSString* editListString = NSLocalizedString(([NSString stringWithFormat: @"Edit %@", listType]), @"Edit list button / menu item");
    
    editBlocklistButton_.title = editListString;
    editBlocklistMenuItem_.title = editListString;

	[refreshUILock_ unlock];
    [self.scheduleController refresh];
    [self.statusItemController refresh];
}

- (void)handleDaemonConfigurationChangedNotification {
    [self.scheduleController refreshSharedPolicyFromDaemonWithCompletion:^(NSError *error) {
        if (!error) [self refreshConfigurationViews];
    }];
}
- (void)handleConfigurationChangedNotification {
    [self refreshConfigurationViews];
    [self.scheduleController syncSharedPolicyIfNeededWithCompletion:nil];
}
- (void)refreshConfigurationViews {
    [SCSentry addBreadcrumb: @"Received configuration changed notification" category: @"app"];
    // if our configuration changed, we should assume the settings may have changed
    [[SCSettings sharedSettings] reloadSettings];
    
    // clean out empty strings from the defaults blocklist (they can end up there occasionally due to UI glitches etc)
    // note we don't screw with the actively running blocklist - that should've been cleaned before it started anyway
    NSArray<NSString*>* cleanedBlocklist = [SCMiscUtilities cleanBlocklist: [defaults_ arrayForKey: @"Blocklist"]];
    [defaults_ setObject: cleanedBlocklist forKey: @"Blocklist"];

    // update our blocklist teaser string
    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 60];
    
    // let the domain list know!
    if (domainListWindowController_ != nil) {
        domainListWindowController_.readOnly = [SCBlockUtilities legacyBlockIsRunning];
        [domainListWindowController_ refreshDomainList];
    }
    
    // let the timer window know!
    if (timerWindowController_ != nil) {
        [timerWindowController_ performSelectorOnMainThread: @selector(configurationChanged)
                                                 withObject: nil
                                              waitUntilDone: NO];
    }
    
    // and our interface may need to change to match!
    [self refreshUserInterface];
}

- (void)showTimerWindow {
	if(timerWindowController_ == nil) {
        [[NSBundle mainBundle] loadNibNamed: @"TimerWindow" owner: self topLevelObjects: nil];
	} else {
		[[timerWindowController_ window] deminiaturize:self];
		[[timerWindowController_ window] makeKeyAndOrderFront: self];
		[[timerWindowController_ window] center];
	}
}

- (void)closeTimerWindow {
	[timerWindowController_ close];
	timerWindowController_ = nil;
}

- (IBAction)showSchedule:(id)sender {
    NSTabView *tabs = (NSTabView *)initialWindow_.contentView;
    [tabs selectTabViewItemWithIdentifier:@"schedule"];
    [self.scheduleController refresh];
    [initialWindow_ deminiaturize:self];
    [initialWindow_ makeKeyAndOrderFront:self];
}

- (IBAction)openPreferences:(id)sender {
    [SCSentry addBreadcrumb: @"Opening preferences window" category: @"app"];
	if (preferencesWindowController_ == nil) {
		NSViewController* generalViewController = [[PreferencesGeneralViewController alloc] init];
		NSViewController* advancedViewController = [[PreferencesAdvancedViewController alloc] init];
		NSString* title = NSLocalizedString(@"Preferences", @"Common title for Preferences window");

		preferencesWindowController_ = [[MASPreferencesWindowController alloc] initWithViewControllers: @[generalViewController, advancedViewController] title: title];
	}
	[preferencesWindowController_ showWindow: nil];
}

- (IBAction)showGetStartedWindow:(id)sender {
    [SCSentry addBreadcrumb: @"Showing \"Get Started\" window" category: @"app"];
	if (!getStartedWindowController) {
		getStartedWindowController = [[NSWindowController alloc] initWithWindowNibName: @"FirstTime"];
	}
	[getStartedWindowController.window center];
	[getStartedWindowController.window makeKeyAndOrderFront: nil];
	[getStartedWindowController showWindow: nil];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [self handleDaemonConfigurationChangedNotification];
}

- (SCStatusItemState *)stateForStatusItemController:(SCStatusItemController *)controller {
    [settings_ reloadSettings];
    NSDate *now = NSDate.date;
    BOOL modern = [SCBlockUtilities modernBlockIsRunning];
    BOOL legacy = !modern && [SCBlockUtilities legacyBlockIsRunning];
    NSDate *end = modern ? [settings_ valueForKey:@"BlockEndDate"] : legacy ? [SCMigrationUtilities legacyBlockEndDate] : nil;
    SCStatusItemBlockPhase block = modern ? SCStatusItemBlockModern : legacy ? SCStatusItemBlockLegacy : SCStatusItemBlockIdle;
    if ((modern || legacy) && (!end || [end compare:now] != NSOrderedDescending)) block = SCStatusItemBlockFinishing;
    BOOL allowlist = modern ? [settings_ boolForKey:@"ActiveBlockAsWhitelist"] : [defaults_ boolForKey:@"BlockAsWhitelist"];
    NSDate *until = [settings_ valueForKey:@"WebsiteBreakUntil"];
    NSDate *next = [settings_ valueForKey:@"WebsiteBreakNextAvailable"];
    SCWebsiteBreakPhase websiteBreak = SCWebsiteBreakPhaseAtDate(block == SCStatusItemBlockModern, allowlist, timerWindowController_.websiteBreakPending, until, next, now);
    SCStatusItemBreakPhase breakPhase;
    switch (websiteBreak) {
        case SCWebsiteBreakReady: breakPhase = SCStatusItemBreakReady; break;
        case SCWebsiteBreakPending: breakPhase = SCStatusItemBreakPending; break;
        case SCWebsiteBreakActive: breakPhase = SCStatusItemBreakActive; break;
        case SCWebsiteBreakCooldown: breakPhase = SCStatusItemBreakCooldown; break;
        default: breakPhase = SCStatusItemBreakUnavailable; break;
    }
    return [[SCStatusItemState alloc] initWithBlockPhase:block breakPhase:breakPhase blockEndDate:end breakTransitionDate:websiteBreak == SCWebsiteBreakActive ? until : next allowlist:allowlist busy:self.addingBlock || timerWindowController_.window.attachedSheet != nil];
}

- (void)statusItemControllerWillHide:(SCStatusItemController *)controller {
    BOOL visible = NO;
    for (NSWindow *window in NSApp.windows) if (window.visible && window.canBecomeKeyWindow) { visible = YES; break; }
    if (!visible) [self showBlockSetup];
}
- (void)statusItemControllerWillOpenMenu:(SCStatusItemController *)controller {
    [settings_ reloadSettings];
}
- (void)showBlockSetup {
    [(NSTabView *)initialWindow_.contentView selectTabViewItemWithIdentifier:@"manual"];
    [initialWindow_ deminiaturize:self];
    [initialWindow_ makeKeyAndOrderFront:self];
}
- (void)statusItemController:(SCStatusItemController *)controller performCommand:(SCStatusItemCommand)command {
    SCStatusItemState *state = [self stateForStatusItemController:controller];
    if (command == SCStatusItemCommandQuit) { [NSApp terminate:self]; return; }
    [NSApp activateIgnoringOtherApps:YES];
    switch (command) {
        case SCStatusItemCommandAddWebsites:
            if (state.blockPhase != SCStatusItemBlockModern || state.busy) break;
            if (state.allowlist) break;
            [self showTimerWindow];
            [timerWindowController_ addToBlock:self];
            break;
        case SCStatusItemCommandOpen:
            if (state.blockPhase == SCStatusItemBlockIdle) [self showBlockSetup]; else [self showTimerWindow];
            break;
        case SCStatusItemCommandPreferences: [self openPreferences:self]; break;
        default: break;
    }
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    // For test runs, we don't want to pop up the dialog to move to the Applications folder, as it breaks the tests
    if (NSProcessInfo.processInfo.environment[@"XCTestConfigurationFilePath"] == nil) {
        PFMoveToApplicationsFolderIfNecessary();
    }
}

- (void)configureMainSections {
    NSView *manualControls = initialWindow_.contentView;
    NSTabView *tabs = [[NSTabView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 840)];
    tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scheduleController = [[SCWeeklyScheduleViewController alloc] initWithClient:self.xpc];
    __weak typeof(self) weakSelf = self;
    self.scheduleController.editBlocklist = ^{ [weakSelf showDomainList:nil]; };
    NSTabViewItem *schedule = [[NSTabViewItem alloc] initWithIdentifier:@"schedule"];
    schedule.label = @"Schedule"; schedule.view = self.scheduleController.view;
    [tabs addTabViewItem:schedule];
    NSTabViewItem *manual = [[NSTabViewItem alloc] initWithIdentifier:@"manual"];
    manual.label = @"Block now";
    NSView *manualView = [[NSView alloc] initWithFrame:tabs.bounds];
    NSTextField *title = [NSTextField labelWithString:@"Block now"];
    title.font = [NSFont systemFontOfSize:25 weight:NSFontWeightSemibold];
    NSTextField *description = [NSTextField labelWithString:@"Start a timer whenever you need it. Your weekly schedule continues in the background."];
    description.font = [NSFont systemFontOfSize:12]; description.textColor = NSColor.secondaryLabelColor;
    for (NSView *view in @[title, description, manualControls]) { view.translatesAutoresizingMaskIntoConstraints = NO; [manualView addSubview:view]; }
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:manualView.leadingAnchor constant:24],
        [title.topAnchor constraintEqualToAnchor:manualView.topAnchor constant:24],
        [description.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [description.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10],
        [manualControls.topAnchor constraintEqualToAnchor:description.bottomAnchor constant:30],
        [manualControls.centerXAnchor constraintEqualToAnchor:manualView.centerXAnchor],
        [manualControls.widthAnchor constraintEqualToConstant:620],
        [manualControls.heightAnchor constraintEqualToConstant:154]
    ]];
    manual.view = manualView; [tabs addTabViewItem:manual];
    initialWindow_.styleMask |= NSWindowStyleMaskResizable;
    initialWindow_.contentView = tabs;
    initialWindow_.contentMinSize = NSMakeSize(720, 700);
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    [initialWindow_ setContentSize:NSMakeSize(MIN(1000, MAX(720, NSWidth(screen) - 40)), MIN(840, MAX(700, NSHeight(screen) - 50)))];
    [tabs selectTabViewItem:schedule];
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	[NSApplication sharedApplication].delegate = self;
    
    [SCSentry startSentry: @"org.eyebeam.SelfControl"];

    settings_ = [SCSettings sharedSettings];
    // go copy over any preferences from legacy setting locations
    // (we won't clear any old data yet - we leave that to the daemon)
    if ([SCMigrationUtilities legacySettingsFoundForCurrentUser]) {
        [SCMigrationUtilities copyLegacySettingsToDefaults];
    }

    // start up our daemon XPC
    self.xpc = [SCXPCClient new];
    [self.xpc connectToHelperTool];
    [self configureMainSections];
    self.statusItemController = [[SCStatusItemController alloc] initWithDelegate:self];
    
    // if we don't have a connection within 0.5 seconds,
    // OR we get back a connection with an old daemon version
    // AND we're running a modern block (which should have a daemon running it)
    // something's wrong with our app-daemon connection. This probably means one of two things:
    //   1. The daemon got unloaded somehow and failed to restart. This is a big problem because the block won't come off.
    //   2. The daemon doesn't want to talk to us anymore, potentially because we've changed our signing certificate. This is a
    //      smaller problem, but still not great because the app can't communicate anything to the daemon.
    //   3. There's a daemon but it's an old version, and should be replaced.
    // in any case, let's go try to reinstall the daemon
    // (we debounce this call so it happens only once, after the connection has been invalidated for an extended period)
    if ([SCBlockUtilities modernBlockIsRunning]) {
        [NSTimer scheduledTimerWithTimeInterval: 0.5 repeats: NO block:^(NSTimer * _Nonnull timer) {
            [self.xpc getVersion:^(NSString * _Nonnull daemonVersion, NSError * _Nonnull error) {
                if (error == nil) {
                    if ([SELFCONTROL_VERSION_STRING compare: daemonVersion options: NSNumericSearch] == NSOrderedDescending) {
                        NSLog(@"Daemon version of %@ is out of date (current version is %@).", daemonVersion, SELFCONTROL_VERSION_STRING);
                        [SCSentry addBreadcrumb: @"Detected out-of-date daemon" category: @"app"];
                        [self reinstallDaemon];
                    } else {
                        [SCSentry addBreadcrumb: @"Detected up-to-date daemon" category:@"app"];
                        NSLog(@"Daemon version of %@ is up-to-date!", daemonVersion);
                    }
                } else {
                    NSLog(@"ERROR: Fetching daemon version failed with error %@", error);
                    [self reinstallDaemon];
                }
            }];
        }];
    }

    // Register observers on both distributed and normal notification centers
	// to receive notifications from the helper tool and the other parts of the
	// main SelfControl app.  Note that they are divided thusly because distributed
	// notifications are very expensive and should be minimized.
	[[NSDistributedNotificationCenter defaultCenter] addObserver: self
														selector: @selector(handleDaemonConfigurationChangedNotification)
															name: @"SCConfigurationChangedNotification"
														  object: nil
                                              suspensionBehavior: NSNotificationSuspensionBehaviorDeliverImmediately];
	[[NSNotificationCenter defaultCenter] addObserver: self
											 selector: @selector(handleConfigurationChangedNotification)
												 name: @"SCConfigurationChangedNotification"
											   object: nil];

	[initialWindow_ center];

	// We'll set blockIsOn to whatever is NOT right, so that in refreshUserInterface
	// it'll fix it and properly refresh the user interface.
	blockIsOn = ![SCUIUtilities blockIsRunning];

	// Change block duration slider for hidden user defaults settings
    blockDurationSlider_.maxDuration = [defaults_ integerForKey: @"MaxBlockLength"];
    [blockDurationSlider_ bindDurationToObject: [NSUserDefaultsController sharedUserDefaultsController]
                                       keyPath: @"values.BlockDuration"];
    
    blocklistTeaserLabel_.stringValue = [SCUIUtilities blockTeaserStringWithMaxLength: 60];

	[self refreshUserInterface];
    
    NSOperatingSystemVersion minRequiredVersion = (NSOperatingSystemVersion){10,10,0}; // Yosemite
    NSString* minRequiredVersionString = @"10.10 (Yosemite)";
	if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion: minRequiredVersion]) {
		NSLog(@"ERROR: Unsupported version for SelfControl");
        [SCSentry captureMessage: @"Unsupported operating system version"];
		NSAlert* unsupportedVersionAlert = [[NSAlert alloc] init];
		[unsupportedVersionAlert setMessageText: NSLocalizedString(@"Unsupported version", nil)];
        [unsupportedVersionAlert setInformativeText: [NSString stringWithFormat: NSLocalizedString(@"This version of SelfControl only supports Mac OS X version %@ or higher. To download a version for older operating systems, please go to www.selfcontrolapp.com", nil), minRequiredVersionString]];
		[unsupportedVersionAlert addButtonWithTitle: NSLocalizedString(@"OK", nil)];
		[unsupportedVersionAlert runModal];
	}
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.statusItemController invalidate];
    [settings_ synchronizeSettings];
}

- (void)reinstallDaemon {
    NSLog(@"Attempting to reinstall daemon...");
    [SCSentry addBreadcrumb: @"Reinstalling daemon" category:@"app"];
    [self.xpc installDaemon:^(NSError * _Nonnull error) {
        if (error == nil) {
            NSLog(@"Reinstalled daemon successfully!");
            [SCSentry addBreadcrumb: @"Daemon reinstalled successfully" category:@"app"];
            
            NSLog(@"Retrying helper tool connection...");
            [self.xpc performSelectorOnMainThread: @selector(connectToHelperTool) withObject: nil waitUntilDone: YES];
        } else {
            if (![SCMiscUtilities errorIsAuthCanceled: error]) {
                NSLog(@"ERROR: Reinstalling daemon failed with error %@", error);
                [SCUIUtilities presentError: error];
            }
        }
    }];
}

- (IBAction)showDomainList:(id)sender {
    [SCSentry addBreadcrumb: @"Showing domain list" category:@"app"];

	if(domainListWindowController_ == nil) {
        [[NSBundle mainBundle] loadNibNamed: @"DomainList" owner: self topLevelObjects: nil];
	}
    domainListWindowController_.readOnly = [SCBlockUtilities legacyBlockIsRunning];
    [domainListWindowController_ showWindow: self];
}

- (void)closeDomainList {
	[domainListWindowController_ close];
	domainListWindowController_ = nil;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed: (NSApplication*) theApplication {
    if ([defaults_ boolForKey:@"ShowMenuBarItem"]) return NO;
	// Hack to make the application terminate after the last window is closed, but
	// INCLUDE the HUD-style timer window.
	if([[timerWindowController_ window] isVisible])
		return NO;
    
    if (PFMoveIsInProgress())
        return NO;
    
	return YES;
}

- (void)addToBlockList:(NSString*)host lock:(NSLock*)lock {
    NSLog(@"addToBlocklist: %@", host);
    // Note we RETRIEVE the latest list from settings (ActiveBlocklist), but we SET the new list in defaults
    // since the helper daemon should be the only one changing ActiveBlocklist
    NSMutableArray* list = [[settings_ valueForKey: @"ActiveBlocklist"] mutableCopy];
    NSArray<NSString*>* cleanedEntries = [SCMiscUtilities cleanBlocklistEntry: host];
    
    if (cleanedEntries.count == 0) return;
    
    for (NSUInteger i = 0; i < cleanedEntries.count; i++) {
        NSString* entry = cleanedEntries[i];
        // don't add duplicate entries
        if (![list containsObject: entry]) {
            [list addObject: entry];
        }
    }
       
	[defaults_ setValue: list forKey: @"Blocklist"];

	if(![SCUIUtilities blockIsRunning]) {
		// This method shouldn't be getting called, a block is not on.
		// so the Start button should be disabled.
		// Maybe the UI didn't get properly refreshed, so try refreshing it again
		// before we return.
		[self refreshUserInterface];

        NSError* err = [SCErr errorWithCode: 102];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];

		return;
	}

	if([defaults_ boolForKey: @"VerifyInternetConnection"] && ![SCUIUtilities networkConnectionIsAvailable]) {
		NSAlert* networkUnavailableAlert = [[NSAlert alloc] init];
		[networkUnavailableAlert setMessageText: NSLocalizedString(@"No network connection detected", "No network connection detected message")];
		[networkUnavailableAlert setInformativeText:NSLocalizedString(@"A block cannot be started without a working network connection.  You can override this setting in Preferences.", @"Message when network connection is unavailable")];
		[networkUnavailableAlert addButtonWithTitle: NSLocalizedString(@"OK", "OK button")];
        [networkUnavailableAlert runModal];
		return;
	}

    [NSThread detachNewThreadSelector: @selector(updateActiveBlocklist:) toTarget: self withObject: lock];
}

- (void)extendBlockTime:(NSInteger)minutesToAdd lock:(NSLock*)lock {
    // sanity check: extending a block for 0 minutes is useless; 24 hour should be impossible
    NSInteger maxBlockLength = [defaults_ integerForKey: @"MaxBlockLength"];
    if(minutesToAdd < 1) return;
    if (minutesToAdd > maxBlockLength) {
        minutesToAdd = maxBlockLength;
    }
    
    // ensure block health before we try to change it
    if(![SCUIUtilities blockIsRunning]) {
        // This method shouldn't be getting called, a block is not on.
        // so the Start button should be disabled.
        // Maybe the UI didn't get properly refreshed, so try refreshing it again
        // before we return.
        [self refreshUserInterface];
        
        NSError* err = [SCErr errorWithCode: 103];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
        
        return;
    }
  
    [self updateBlockEndDate: lock minutesToAdd: minutesToAdd];
//    [NSThread detachNewThreadSelector: @selector(extendBlockDuration:)
//                             toTarget: self
//                           withObject: @{
//                                         @"lock": lock,
//                                         @"minutesToAdd": @(minutesToAdd)
//                                                                                                    }];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver: self
													name: @"SCConfigurationChangedNotification"
												  object: nil];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver: self
															   name: @"SCConfigurationChangedNotification"
															 object: nil];
}

- (id)initialWindow {
	return initialWindow_;
}

- (id)domainListWindowController {
	return domainListWindowController_;
}

- (void)setDomainListWindowController:(id)newController {
	domainListWindowController_ = newController;
}

- (void)installBlock {
    [SCSentry addBreadcrumb: @"App running installBlock method" category:@"app"];
	@autoreleasepool {
		self.addingBlock = true;

        // if there are any ongoing edits in the domain list, make sure they make it in
        if (domainListWindowController_ != nil) {
            [domainListWindowController_ refreshDomainList];
        }
		[self refreshUserInterface];

        [self.xpc installDaemon:^(NSError * _Nonnull error) {
            if (error != nil) {
                [SCUIUtilities presentError: error];
                self.addingBlock = false;
                [self refreshUserInterface];
                return;
            } else {
                [SCSentry addBreadcrumb: @"Daemon installed successfully (en route to installing block)" category:@"app"];
                // helper tool installed successfully, let's prepare to start the block!
                // for legacy reasons, BlockDuration is in minutes, so convert it to seconds before passing it through]
                // sanity check duration (must be above zero)
                NSTimeInterval blockDurationSecs = MAX([[self->defaults_ valueForKey: @"BlockDuration"] intValue] * 60, 0);
                NSDate* newBlockEndDate = [NSDate dateWithTimeIntervalSinceNow: blockDurationSecs];
                
                // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
                [self->settings_ synchronizeSettings];
                [self->defaults_ synchronize];

                // ok, the new helper tool is installed! refresh the connection, then it's time to start the block
                [self.xpc refreshConnectionAndRun:^{
                    NSLog(@"Refreshed connection and ready to start block!");
                    [self.xpc startBlockWithControllingUID: getuid()
                                                 blocklist: [self->defaults_ arrayForKey: @"Blocklist"]
                                               isAllowlist: [self->defaults_ boolForKey: @"BlockAsWhitelist"]
                                                   endDate: newBlockEndDate
                                             blockSettings: @{
                                                                @"ClearCaches": [self->defaults_ valueForKey: @"ClearCaches"],
                                                                @"AllowLocalNetworks": [self->defaults_ valueForKey: @"AllowLocalNetworks"],
                                                                @"EvaluateCommonSubdomains": [self->defaults_ valueForKey: @"EvaluateCommonSubdomains"],
                                                                @"IncludeLinkedDomains": [self->defaults_ valueForKey: @"IncludeLinkedDomains"],
                                                                @"BlockSoundShouldPlay": [self->defaults_ valueForKey: @"BlockSoundShouldPlay"],
                                                                @"BlockSound": [self->defaults_ valueForKey: @"BlockSound"],
                                                                @"EnableErrorReporting": [self->defaults_ valueForKey: @"EnableErrorReporting"]
                                                            }
                                                     reply:^(NSError * _Nonnull error) {
                        if (error != nil) {
                            [SCUIUtilities presentError: error];
                        } else {
                            [SCSentry addBreadcrumb: @"Block started successfully" category:@"app"];
                        }
                        
                        // get the new settings
                        [self->settings_ synchronizeSettingsWithCompletion:^(NSError * _Nullable error) {
                            self.addingBlock = false;
                            [self refreshUserInterface];
                        }];
                    }];
                }];
            }
        }];
	}
}

- (void)updateActiveBlocklist:(NSLock*)lockToUse {
	if(![lockToUse tryLock]) {
		return;
	}
    
    [SCSentry addBreadcrumb: @"App running updateActiveBlocklist method" category:@"app"];

    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];
    [defaults_ synchronize];

    [self.xpc refreshConnectionAndRun:^{
        NSLog(@"Refreshed connection updating active blocklist!");
        [self.xpc updateBlocklist: [self->defaults_ arrayForKey: @"Blocklist"]
                            reply:^(NSError * _Nonnull error) {
            [self->timerWindowController_ performSelectorOnMainThread:@selector(closeAddSheet:) withObject: self waitUntilDone: YES];
            
            if (error != nil) {
                [SCUIUtilities presentError: error];
            } else {
                [SCSentry addBreadcrumb: @"Blocklist updated successfully" category:@"app"];
            }
            
            [lockToUse unlock];
        }];
    }];
}

// it really sucks, but we can't change any values that are KVO-bound to the UI unless they're on the main thread
// to make that easier, here is a helper that always does it on the main thread
- (void)setDefaultsBlockDurationOnMainThread:(NSNumber*)newBlockDuration {
    if (![NSThread isMainThread]) {
        [self performSelectorOnMainThread: @selector(setDefaultsBlockDurationOnMainThread:) withObject:newBlockDuration waitUntilDone: YES];
    }

    [defaults_ setInteger: [newBlockDuration intValue] forKey: @"BlockDuration"];
}

- (void)updateBlockEndDate:(NSLock*)lockToUse minutesToAdd:(NSInteger)minutesToAdd {
    if(![lockToUse tryLock]) {
        return;
    }
    [SCSentry addBreadcrumb: @"App running updateBlockEndDate method" category:@"app"];

    minutesToAdd = MAX(minutesToAdd, 0); // make sure there's no funny business with negative minutes
    NSDate* oldBlockEndDate = [settings_ valueForKey: @"BlockEndDate"];
    NSDate* newBlockEndDate = [oldBlockEndDate dateByAddingTimeInterval: (minutesToAdd * 60)];

    // we're about to launch a helper tool which will read settings, so make sure the ones on disk are valid
    [settings_ synchronizeSettings];
    [defaults_ synchronize];

    [self.xpc refreshConnectionAndRun:^{
        // Before we try to extend the block, make sure the block time didn't run out (or is about to run out) in the meantime
        if ([SCBlockUtilities currentBlockIsExpired] || [oldBlockEndDate timeIntervalSinceNow] < 1) {
            // we're done, or will be by the time we get to it! so just let it expire. they can restart it.
            [lockToUse unlock];
            return;
        }

        NSLog(@"Refreshed connection updating active block end date!");
        [self.xpc updateBlockEndDate: newBlockEndDate
                               reply:^(NSError * _Nonnull error) {
            [self->timerWindowController_ performSelectorOnMainThread:@selector(closeAddSheet:) withObject: self waitUntilDone: YES];

            if (error != nil) {
                [SCUIUtilities presentError: error];
            } else {
                [SCSentry addBreadcrumb: @"App extended block duration successfully" category:@"app"];
            }
            
            [lockToUse unlock];
        }];
    }];
}

- (IBAction)save:(id)sender {
	NSSavePanel *sp;
	long runResult;

	/* create or get the shared instance of NSSavePanel */
	sp = [NSSavePanel savePanel];
	sp.allowedFileTypes = @[@"selfcontrol"];

	/* display the NSSavePanel */
	runResult = [sp runModal];

	/* if successful, save file under designated name */
	if (runResult == NSModalResponseOK) {
        NSError* err;
        [SCBlockFileReaderWriter writeBlocklistToFileURL: sp.URL
                                   blockInfo: @{
                                       @"Blocklist": [defaults_ arrayForKey: @"Blocklist"],
                                       @"BlockAsWhitelist": [defaults_ objectForKey: @"BlockAsWhitelist"]
                                       
                                   }
                                   error: &err];

        if (err != nil) {
            NSError* displayErr = [SCErr errorWithCode: 101 subDescription: err.localizedDescription];
            [SCSentry captureError: displayErr];
            NSBeep();
            [SCUIUtilities presentError: displayErr];
			return;
        } else {
            [SCSentry addBreadcrumb: @"Saved blocklist to file" category:@"app"];
        }
	}
}

- (BOOL)openSavedBlockFileAtURL:(NSURL*)fileURL {
    NSDictionary* settingsFromFile = [SCBlockFileReaderWriter readBlocklistFromFile: fileURL];
    
    if (settingsFromFile != nil) {
        [defaults_ setObject: settingsFromFile[@"Blocklist"] forKey: @"Blocklist"];
        [defaults_ setObject: settingsFromFile[@"BlockAsWhitelist"] forKey: @"BlockAsWhitelist"];
        [SCSentry addBreadcrumb: @"Opened blocklist from file" category:@"app"];
    } else {
        NSLog(@"WARNING: Could not read a valid blocklist from file - ignoring.");
        return NO;
    }

    // send a notification so the domain list (etc) updates
    [[NSNotificationCenter defaultCenter] postNotificationName: @"SCConfigurationChangedNotification" object: self];
    
    [self refreshUserInterface];
    return YES;
}

- (IBAction)open:(id)sender {
	NSOpenPanel* oPanel = [NSOpenPanel openPanel];
	oPanel.allowedFileTypes = @[@"selfcontrol"];
	oPanel.allowsMultipleSelection = NO;

	long result = [oPanel runModal];
	if (result == NSModalResponseOK) {
		if([oPanel.URLs count] > 0) {
            [self openSavedBlockFileAtURL: oPanel.URLs[0]];
		}
	}
}

- (BOOL)application:(NSApplication*)theApplication openFile:(NSString*)filename {
    return [self openSavedBlockFileAtURL: [NSURL fileURLWithPath: filename]];
}

- (IBAction)openFAQ:(id)sender {
    [SCSentry addBreadcrumb: @"Opened SelfControl FAQ" category:@"app"];
	NSURL *url=[NSURL URLWithString: @"https://github.com/SelfControlApp/selfcontrol/wiki/FAQ#q-selfcontrols-timer-is-at-0000-and-i-cant-start-a-new-block-and-im-freaking-out"];
	[[NSWorkspace sharedWorkspace] openURL: url];
}

- (IBAction)openSupportHub:(id)sender {
    [SCSentry addBreadcrumb: @"Opened SelfControl Support Hub" category:@"app"];
    NSURL *url=[NSURL URLWithString: @"https://selfcontrolapp.com/support"];
    [[NSWorkspace sharedWorkspace] openURL: url];
}


@end
