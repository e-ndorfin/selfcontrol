//
//  PreferencesGeneralViewController.m
//  SelfControl
//
//  Created by Charles Stigler on 9/27/14.
//
//

#import "PreferencesGeneralViewController.h"
#import "SCSettings.h"
#import "SCUIUtilities.h"

@interface PreferencesGeneralViewController ()

@end

@implementation PreferencesGeneralViewController

- (instancetype)init {
    return [super initWithNibName: @"PreferencesGeneralViewController" bundle: nil];
}

- (void)viewDidLoad  {
    [super viewDidLoad];
    // set the valid sounds in the Block Sound menu
    [self.soundMenu removeAllItems];
    [self.soundMenu addItemsWithTitles: SCConstants.systemSoundNames];
    [self.view setFrameSize:NSMakeSize(NSWidth(self.view.frame), NSHeight(self.view.frame) + 68)];
    NSButton *showMenu = [[NSButton alloc] initWithFrame:NSMakeRect(20, 40, 440, 22)];
    showMenu.buttonType = NSSwitchButton;
    showMenu.title = NSLocalizedStringFromTable(@"Show SelfControl in the menu bar", @"StatusItem", @"menu bar preference");
    [showMenu bind:NSValueBinding toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:@"values.ShowMenuBarItem" options:nil];
    [self.view addSubview:showMenu];
    NSButton *countdown = [[NSButton alloc] initWithFrame:NSMakeRect(40, 12, 420, 22)];
    countdown.buttonType = NSSwitchButton;
    countdown.title = NSLocalizedStringFromTable(@"Show remaining time beside the menu bar icon", @"StatusItem", @"menu bar countdown preference");
    [countdown bind:NSValueBinding toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:@"values.ShowMenuBarCountdown" options:nil];
    [countdown bind:NSEnabledBinding toObject:NSUserDefaultsController.sharedUserDefaultsController withKeyPath:@"values.ShowMenuBarItem" options:nil];
    [self.view addSubview:countdown];
}

- (IBAction)soundSelectionChanged:(NSPopUpButton*)sender {
	// Map the tags used in interface builder to the sound
    NSArray<NSString*>* systemSoundNames = SCConstants.systemSoundNames;
	
    NSString* selectedSoundName = sender.titleOfSelectedItem;
    NSUInteger blockSoundIndex = [systemSoundNames indexOfObject: selectedSoundName];
    if (blockSoundIndex == NSNotFound) {
        NSLog(@"WARNING: User selected unknown alert sound %@.", selectedSoundName);
        NSError* err = [SCErr errorWithCode: 310];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
        return;
    }

    // now play the sound to preview it for the user
    NSSound* alertSound = [NSSound soundNamed: systemSoundNames[blockSoundIndex]];
	if(!alertSound) {
		NSLog(@"WARNING: Alert sound not found.");
        NSError* err = [SCErr errorWithCode: 311];
        [SCSentry captureError: err];
        [SCUIUtilities presentError: err];
	} else {
		[alertSound play];
	}
}

#pragma mark MASPreferencesViewController

- (NSString*)identifier {
	return @"GeneralPreferences";
}
- (NSImage *)toolbarItemImage {
	return [NSImage imageNamed: NSImageNamePreferencesGeneral];
}

- (NSString *)toolbarItemLabel {
	return NSLocalizedString(@"General", @"Toolbar item name for the General preference pane");
}

@end
