#import "SCWeeklyScheduleViewController.h"
#import <unistd.h>
#import "SCWeeklyCalendarView.h"
#import "SCWeeklySchedule.h"
#import "SCXPCClient.h"
#import "SCUIUtilities.h"
#import "SCFriendProtection.h"

@interface SCWeeklyScheduleContentView : NSView
@property (copy) void (^layoutContents)(void);
@end
@implementation SCWeeklyScheduleContentView
- (BOOL)isFlipped { return YES; }
- (void)layout { [super layout]; if (self.layoutContents) self.layoutContents(); }
@end

@interface SCWeeklyScheduleViewController ()
@property SCXPCClient *client;
@property SCWeeklyCalendarView *calendarView;
@property NSTextField *heading;
@property NSTextField *instructions;
@property NSTextField *statusLabel;
@property NSTextField *summaryLabel;
@property NSTextField *listLabel;
@property NSTextField *footnote;
@property NSButton *enabledButton;
@property NSButton *saveButton;
@property NSButton *clearButton;
@property NSButton *editButton;
@property NSButton *addWebsitesButton;
@property NSPopUpButton *dayPicker;
@property NSPopUpButton *startPicker;
@property NSPopUpButton *endPicker;
@property NSButton *addRangeButton;
@property NSDictionary *savedConfiguration;
@property NSString *daemonError;
@property BOOL dirty;
@property BOOL busy;
@property BOOL fetching;
@property BOOL helperUnavailable;
@property NSTimer *timer;
@property NSButton *passwordButton;
@property NSTextField *passwordLabel;
@property BOOL friendProtectionEnabled;
@property BOOL passwordPromptVisible;
@end

@implementation SCWeeklyScheduleViewController
- (instancetype)initWithClient:(SCXPCClient *)client {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _client = client;
        _savedConfiguration = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"WeeklyScheduleSavedConfiguration"];
        _dirty = [NSUserDefaults.standardUserDefaults boolForKey:@"WeeklyScheduleDraftDirty"];
        _friendProtectionEnabled = [NSUserDefaults.standardUserDefaults boolForKey:@"FriendProtectionEnabled"];
    }
    return self;
}
- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.view addSubview:label];
    return label;
}
- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    [self.view addSubview:button]; return button;
}
- (void)loadView {
    SCWeeklyScheduleContentView *root = [[SCWeeklyScheduleContentView alloc] initWithFrame:NSMakeRect(0, 0, 960, 790)];
    self.view = root;
    self.heading = [self label:@"Weekly schedule" size:25 weight:NSFontWeightSemibold];
    self.instructions = [self label:@"Drag across days and times to block. Drag over selected time to erase." size:12 weight:NSFontWeightRegular];
    self.instructions.textColor = NSColor.secondaryLabelColor;
    self.enabledButton = [NSButton checkboxWithTitle:@"Enable weekly schedule" target:self action:@selector(draftChanged:)];
    [root addSubview:self.enabledButton];
    self.saveButton = [self button:@"Save schedule" action:@selector(saveSchedule:)];
    self.clearButton = [self button:@"Clear week" action:@selector(clearWeek:)];
    self.statusLabel = [self label:@"Schedule off · blocks can still be started under Block now." size:12 weight:NSFontWeightMedium];
    self.calendarView = [[SCWeeklyCalendarView alloc] initWithFrame:NSZeroRect];
    [root addSubview:self.calendarView];
    self.summaryLabel = [self label:@"No blocking times selected" size:12 weight:NSFontWeightRegular];
    self.summaryLabel.textColor = NSColor.secondaryLabelColor;
    self.dayPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.dayPicker addItemsWithTitles:@[@"Monday", @"Tuesday", @"Wednesday", @"Thursday", @"Friday", @"Saturday", @"Sunday"]];
    self.dayPicker.accessibilityLabel = @"Day to add";
    self.startPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.startPicker.accessibilityLabel = @"Start time";
    self.endPicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.endPicker.accessibilityLabel = @"End time";
    for (NSUInteger row = 0; row < 48; row++) {
        [self.startPicker addItemWithTitle:[NSString stringWithFormat:@"%02lu:%02lu", row / 2, row % 2 * 30]];
        [self.endPicker addItemWithTitle:[NSString stringWithFormat:@"%02lu:%02lu", (row + 1) / 2, (row + 1) % 2 * 30]];
    }
    [self.startPicker selectItemAtIndex:18]; [self.endPicker selectItemAtIndex:33];
    [root addSubview:self.dayPicker]; [root addSubview:self.startPicker]; [root addSubview:self.endPicker];
    self.addRangeButton = [self button:@"Add time" action:@selector(addRange:)];
    self.listLabel = [self label:@"Shared blocklist" size:12 weight:NSFontWeightMedium];
    self.editButton = [self button:@"Edit list…" action:@selector(editList:)];
    self.addWebsitesButton = [self button:@"Add websites…" action:@selector(addWebsites:)];
    self.passwordLabel = [self label:@"No friend password set" size:12 weight:NSFontWeightMedium];
    self.passwordButton = [self button:@"Set a password" action:@selector(passwordAction:)];
    self.footnote = [self label:@"" size:11 weight:NSFontWeightRegular];
    self.footnote.textColor = NSColor.secondaryLabelColor;
    self.footnote.maximumNumberOfLines = 2;
    self.footnote.lineBreakMode = NSLineBreakByWordWrapping;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *slots = [defaults arrayForKey:@"WeeklyScheduleDraftSlots"] ?: self.savedConfiguration[@"slots"] ?: @[];
    self.calendarView.selectedSlots = [SCWeeklySchedule indexesFromSlots:slots];
    BOOL enabled = [defaults objectForKey:@"WeeklyScheduleDraftEnabled"] ? [defaults boolForKey:@"WeeklyScheduleDraftEnabled"] : [self.savedConfiguration[@"enabled"] boolValue];
    self.enabledButton.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    __weak typeof(self) weakSelf = self;
    self.calendarView.selectionChanged = ^{ [weakSelf draftChanged:nil]; };
    root.layoutContents = ^{ [weakSelf layoutContents]; };
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateInterface];
        if (weakSelf.savedConfiguration) [weakSelf fetchStatus];
    }];
    [self layoutContents]; [self updateInterface]; [self fetchStatus];
}
- (void)layoutContents {
    CGFloat w = NSWidth(self.view.bounds), h = NSHeight(self.view.bounds);
    self.heading.frame = NSMakeRect(24, 18, w - 48, 34);
    self.instructions.frame = NSMakeRect(24, 59, w - 48, 20);
    self.enabledButton.frame = NSMakeRect(24, 89, 250, 24);
    self.saveButton.frame = NSMakeRect(w - 174, 86, 150, 32);
    self.clearButton.frame = NSMakeRect(w - 290, 86, 108, 32);
    self.statusLabel.frame = NSMakeRect(24, 127, w - 48, 20);
    self.calendarView.frame = NSMakeRect(24, 159, w - 48, h - 359);
    CGFloat row = h - 183;
    self.summaryLabel.frame = NSMakeRect(24, row, w - 48, 18);
    self.dayPicker.frame = NSMakeRect(24, row + 26, 130, 28);
    self.startPicker.frame = NSMakeRect(164, row + 26, 100, 28);
    self.endPicker.frame = NSMakeRect(274, row + 26, 100, 28);
    self.addRangeButton.frame = NSMakeRect(384, row + 24, 105, 32);
    self.listLabel.frame = NSMakeRect(24, row + 70, w - 375, 20);
    self.editButton.frame = NSMakeRect(w - 289, row + 63, 110, 32);
    self.addWebsitesButton.frame = NSMakeRect(w - 174, row + 63, 150, 32);
    self.passwordLabel.frame = NSMakeRect(24, row + 109, w - 245, 20);
    self.passwordButton.frame = NSMakeRect(w - 210, row + 102, 186, 32);
    self.footnote.frame = NSMakeRect(24, h - 41, w - 48, 36);
}
- (NSDictionary *)draftConfiguration {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *settings = [NSMutableDictionary new];
    for (NSString *key in SCWeeklySchedule.blockSettingKeys) settings[key] = [defaults objectForKey:key];
    return @{@"slots":[SCWeeklySchedule slotsFromIndexes:self.calendarView.selectedSlots], @"enabled":@(self.enabledButton.state == NSControlStateValueOn),
        @"blocklist":[SCMiscUtilities cleanBlocklist:[defaults arrayForKey:@"Blocklist"]], @"isAllowlist":@([defaults boolForKey:@"BlockAsWhitelist"]), @"blockSettings":settings};
}
- (void)persistDraft {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:[SCWeeklySchedule slotsFromIndexes:self.calendarView.selectedSlots] forKey:@"WeeklyScheduleDraftSlots"];
    [defaults setBool:self.enabledButton.state == NSControlStateValueOn forKey:@"WeeklyScheduleDraftEnabled"];
    [defaults setBool:self.dirty forKey:@"WeeklyScheduleDraftDirty"];
}
- (void)draftChanged:(id)sender {
    self.dirty = self.savedConfiguration ? ![[self draftConfiguration] isEqual:self.savedConfiguration] :
        (self.calendarView.selectedSlots.count > 0 || self.enabledButton.state == NSControlStateValueOn);
    [self persistDraft]; [self updateInterface];
}
- (void)clearWeek:(id)sender { [self.calendarView clearSelection]; }
- (void)addRange:(id)sender {
    NSUInteger start = self.startPicker.indexOfSelectedItem, end = self.endPicker.indexOfSelectedItem + 1;
    if (start >= end) {
        NSAlert *alert = [NSAlert new]; alert.messageText = @"Choose an end time after the start time";
        alert.informativeText = @"For overnight blocks, select the end of one day and the start of the following day.";
        [alert beginSheetModalForWindow:self.view.window completionHandler:nil]; return;
    }
    [self.calendarView addDay:self.dayPicker.indexOfSelectedItem fromSlot:start toSlot:end];
}
- (void)editList:(id)sender { if (self.editBlocklist) self.editBlocklist(); }
- (void)refresh { if (self.isViewLoaded) { [self updateInterface]; [self fetchStatus]; } }
- (void)fetchStatus {
    if (self.fetching || self.busy) return;
    [self refreshSharedPolicyFromDaemonWithCompletion:nil];
}
- (void)refreshSharedPolicyFromDaemonWithCompletion:(void (^)(NSError *))completion {
    if (self.fetching || self.busy) {
        if (completion) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
            [self refreshSharedPolicyFromDaemonWithCompletion:completion];
        });
        return;
    }
    self.fetching = YES;
    NSDictionary *baseline = self.savedConfiguration;
    [self.client getWeeklySchedule:^(NSDictionary *status, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.fetching = NO;
            // A local protected commit may have begun while this read was in flight.
            if (self.busy) {
                if (completion) [self refreshSharedPolicyFromDaemonWithCompletion:completion];
                return;
            }
            self.helperUnavailable = error != nil;
            if (!error) {
                self.daemonError = status[@"lastError"];
                self.friendProtectionEnabled = [status[@"friendProtectionEnabled"] boolValue];
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                [defaults setBool:self.friendProtectionEnabled forKey:@"FriendProtectionEnabled"];
                if (!status[@"slots"] && self.savedConfiguration) self.helperUnavailable = YES;
                if (status[@"slots"]) {
                    NSDictionary *saved = [SCWeeklySchedule validatedConfiguration:status error:nil];
                    if (!saved || [status[@"controllingUID"] unsignedIntValue] != getuid()) {
                        self.helperUnavailable = YES;
                        if (completion) completion([NSError errorWithDomain:@"SelfControl.Schedule" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The shared settings are invalid or belong to another Mac user."}]);
                        [self updateInterface]; return;
                    }
                    NSDictionary *mirrored = baseline ? [SCWeeklySchedule sharedPolicy:self.sharedPolicy rebasedFrom:baseline onto:saved] : saved;
                    self.savedConfiguration = saved;
                    [defaults setObject:saved forKey:@"WeeklyScheduleSavedConfiguration"];
                    // Incoming helper updates are authoritative. Mirror them before
                    // any local edit can compare against an obsolete saved list.
                    [defaults setObject:mirrored[@"blocklist"] forKey:@"Blocklist"];
                    [defaults setBool:[mirrored[@"isAllowlist"] boolValue] forKey:@"BlockAsWhitelist"];
                    [mirrored[@"blockSettings"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
                        [defaults setObject:value forKey:key];
                    }];
                    if (!self.dirty) {
                        self.calendarView.selectedSlots = [SCWeeklySchedule indexesFromSlots:saved[@"slots"]];
                        self.enabledButton.state = [saved[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
                    }
                    [self persistDraft];
                }
            }
            [self updateInterface];
            if (completion) {
                // Initial app setup can install a missing helper through the
                // original workflow. Existing saved/protected policies fail closed.
                NSError *failure = error;
                if (self.helperUnavailable && self.savedConfiguration && !failure)
                    failure = [NSError errorWithDomain:@"SelfControl.Schedule" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The saved shared settings are unavailable. Open Schedule to resolve this."}];
                if (!self.savedConfiguration && !self.friendProtectionEnabled) failure = nil;
                completion(failure);
            }
        });
    }];
}
- (void)updateInterface {
    BOOL active = [SCUIUtilities blockIsRunning];
    BOOL editable = !self.busy;
    self.calendarView.editable = editable;
    self.calendarView.needsDisplay = YES;
    self.enabledButton.enabled = editable;
    self.clearButton.enabled = editable && self.calendarView.selectedSlots.count > 0;
    self.dayPicker.enabled = editable; self.startPicker.enabled = editable; self.endPicker.enabled = editable;
    self.addRangeButton.enabled = editable;
    self.editButton.enabled = editable;
    BOOL allowlist = [NSUserDefaults.standardUserDefaults boolForKey:@"BlockAsWhitelist"];
    self.addWebsitesButton.enabled = !self.busy && !allowlist;
    self.dirty = self.savedConfiguration ? ![[self draftConfiguration] isEqual:self.savedConfiguration] :
        (self.calendarView.selectedSlots.count > 0 || self.enabledButton.state == NSControlStateValueOn);
    self.saveButton.enabled = editable && (self.dirty || (self.helperUnavailable && self.calendarView.selectedSlots.count));
    self.saveButton.title = self.busy ? @"Saving…" : @"Save schedule";
    self.passwordButton.enabled = !self.busy;
    self.passwordButton.title = self.friendProtectionEnabled ? @"Turn off password" : @"Set a password";
    self.passwordLabel.stringValue = self.friendProtectionEnabled ? @"Friend password on · approval only to reduce blocking" : @"No friend password set · changes are unrestricted";
    self.summaryLabel.stringValue = self.calendarView.selectedSlots.count ? [NSString stringWithFormat:@"%.1f hours selected per week · 30-minute intervals · blue = blocked", self.calendarView.selectedSlots.count / 2.0] : @"No blocking times selected · select time on the calendar or use Add time";
    NSUInteger sites = [[NSUserDefaults.standardUserDefaults arrayForKey:@"Blocklist"] count];
    self.listLabel.stringValue = [NSString stringWithFormat:@"Shared %@ · %lu %@", allowlist ? @"allowlist" : @"blocklist", sites, sites == 1 ? @"entry" : @"entries"];
    self.statusLabel.textColor = NSColor.labelColor;
    if (active) {
        NSDate *end = [SCSettings.sharedSettings valueForKey:@"BlockEndDate"];
        NSDateFormatter *format = [NSDateFormatter new]; format.dateFormat = @"EEE HH:mm";
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Block active until %@ · saved edits apply immediately%@.", [format stringFromDate:end], self.friendProtectionEnabled ? @"; reducing blocking needs friend approval" : @""];
    } else if (self.daemonError.length) {
        self.statusLabel.stringValue = self.daemonError; self.statusLabel.textColor = NSColor.systemRedColor;
    } else if (self.helperUnavailable && [self.savedConfiguration[@"enabled"] boolValue]) {
        self.statusLabel.stringValue = @"Background helper is unavailable. Save the schedule to reconnect.";
    } else if ([self.savedConfiguration[@"enabled"] boolValue]) {
        NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
        NSDate *next = [SCWeeklySchedule nextStartDateForSlots:self.savedConfiguration[@"slots"] afterDate:NSDate.date calendar:calendar];
        NSDateFormatter *format = [NSDateFormatter new]; format.dateFormat = @"EEE HH:mm";
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Schedule enabled · next block %@ · runs even when SelfControl is closed.", [format stringFromDate:next] ?: @"now"];
    } else {
        self.statusLabel.stringValue = @"Schedule off · blocks can still be started under Block now.";
    }
    NSString *zone = NSTimeZone.localTimeZone.name;
    self.footnote.stringValue = [NSString stringWithFormat:@"%@Times follow this Mac (%@). Schedule edits apply immediately; a separate Block now timer keeps its own end time.", self.dirty ? @"Unsaved changes. " : @"", zone];
}
- (void)presentError:(NSError *)error {
    if ([SCMiscUtilities errorIsAuthCanceled:error]) return;
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Could not update SelfControl"; alert.informativeText = error.localizedDescription;
    [alert beginSheetModalForWindow:self.view.window completionHandler:nil];
}
- (void)saveSchedule:(id)sender {
    if (self.busy) return;
    NSError *validationError;
    NSDictionary *configuration = [SCWeeklySchedule validatedConfiguration:self.draftConfiguration error:&validationError];
    if (!configuration) { [self presentError:validationError]; return; }
    self.busy = YES; [self updateInterface];
    if (!self.helperUnavailable && self.client.isConnected) {
        [self submitSchedule:configuration password:@""];
        return;
    }
    [self.client installDaemon:^(NSError *installError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (installError) { self.busy = NO; [self updateInterface]; [self presentError:installError]; return; }
            [self.client refreshConnectionAndRun:^{
                [self submitSchedule:configuration password:@""];

            }];
        });
    }];
}
- (void)addWebsites:(id)sender {
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Add websites to your blocklist";
    alert.informativeText = @"Separate websites with commas or spaces. Additions apply to the active block and future scheduled blocks.";
    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 390, 28)];
    input.placeholderString = @"example.com, another-site.com";
    input.accessibilityLabel = @"Websites to block";
    alert.accessoryView = input;
    [alert addButtonWithTitle:@"Add websites"]; [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        NSMutableCharacterSet *separators = [NSCharacterSet.whitespaceAndNewlineCharacterSet mutableCopy];
        [separators addCharactersInString:@",;"];
        NSMutableArray *entries = [NSMutableArray new];
        for (NSString *entry in [input.stringValue componentsSeparatedByCharactersInSet:separators])
            [entries addObjectsFromArray:[SCMiscUtilities cleanBlocklistEntry:entry]];
        if (!entries.count) return;
        self.busy = YES; [self updateInterface];
        void (^finish)(NSError *) = ^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                if (error) { [self presentError:error]; [self updateInterface]; return; }
                NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                NSMutableOrderedSet *sites = [NSMutableOrderedSet orderedSetWithArray:[defaults arrayForKey:@"Blocklist"] ?: @[]];
                [sites addObjectsFromArray:entries]; [defaults setObject:sites.array forKey:@"Blocklist"];
                // Keep the saved snapshot in sync without changing unsaved calendar edits.
                if (self.savedConfiguration) {
                    NSMutableDictionary *saved = [self.savedConfiguration mutableCopy];
                    NSMutableOrderedSet *scheduled = [NSMutableOrderedSet orderedSetWithArray:saved[@"blocklist"] ?: @[]];
                    [scheduled addObjectsFromArray:entries]; saved[@"blocklist"] = scheduled.array;
                    self.savedConfiguration = saved;
                    [defaults setObject:saved forKey:@"WeeklyScheduleSavedConfiguration"];
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:@"SCConfigurationChangedNotification" object:self];
                [self updateInterface]; [self fetchStatus];
            });
        };
        if (!self.savedConfiguration && ![SCUIUtilities blockIsRunning]) { finish(nil); return; }
        void (^append)(void) = ^{ [self.client appendWeeklyWebsites:entries reply:finish]; };
        if (self.helperUnavailable && ![SCUIUtilities blockIsRunning]) {
            [self.client installDaemon:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) finish(error);
                    else [self.client refreshConnectionAndRun:append];
                });
            }];
        } else append();
    }];
    [alert.window makeFirstResponder:input];
}

- (BOOL)needsFriendPassword:(NSError *)error {
    return [error.domain isEqual:SCFriendProtectionErrorDomain] && error.code == SCFriendPasswordRequired;
}
- (void)requestFriendPassword:(NSString *)reason approved:(void (^)(NSString *password))approved cancelled:(void (^)(void))cancelled {
    if (self.passwordPromptVisible) { if (cancelled) cancelled(); return; }
    self.passwordPromptVisible = YES;
    [self.view.window makeKeyAndOrderFront:nil];
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Friend approval required";
    alert.informativeText = reason;
    NSSecureTextField *input = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 390, 28)];
    input.placeholderString = @"Friend's password"; input.accessibilityLabel = @"Friend's password";
    alert.accessoryView = input;
    [alert addButtonWithTitle:@"Approve change"]; [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        self.passwordPromptVisible = NO;
        NSString *password = input.stringValue; input.stringValue = @"";
        if (response == NSAlertFirstButtonReturn) approved(password);
        else if (cancelled) cancelled();
    }];
    [alert.window makeFirstResponder:input];
}
- (void)submitSchedule:(NSDictionary *)configuration password:(NSString *)password {
    NSDictionary *baseline = self.savedConfiguration;
    [self.client getWeeklySchedule:^(NSDictionary *status, NSError *readError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (readError) { self.busy = NO; [self presentError:readError]; [self updateInterface]; return; }
            NSMutableDictionary *candidate = [configuration mutableCopy];
            [candidate addEntriesFromDictionary:[SCWeeklySchedule sharedPolicy:configuration rebasedFrom:baseline onto:status]];
            candidate[@"expectedBlocklist"] = status[@"blocklist"] ?: @[];
            [self mirrorSharedPolicy:[SCWeeklySchedule sharedPolicy:self.sharedPolicy rebasedFrom:configuration onto:candidate]];
            [self commitSchedule:candidate password:password];
        });
    }];
}
- (void)commitSchedule:(NSDictionary *)configuration password:(NSString *)password {
    [self.client setWeeklySchedule:configuration friendPassword:password reply:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self needsFriendPassword:error]) {
                NSArray *reasons = [SCFriendProtection reductionReasonsFor:configuration comparedTo:self.savedConfiguration];
                NSString *reason = [NSString stringWithFormat:@"This change reduces blocking%@. Your friend must enter their password to save it.", reasons.count ? [@": " stringByAppendingString:[reasons componentsJoinedByString:@"; "]] : @""];
                [self requestFriendPassword:reason approved:^(NSString *approval) { [self submitSchedule:configuration password:approval]; }
                    cancelled:^{ self.busy = NO; [self updateInterface]; }];
                return;
            }
            if ([error.domain isEqual:@"SelfControl.Schedule"] && error.code == 6) {
                [self submitSchedule:configuration password:password]; return;
            }
            self.busy = NO;
            if (!error) {
                self.savedConfiguration = [SCWeeklySchedule validatedConfiguration:configuration error:nil]; self.dirty = NO; self.helperUnavailable = NO; self.daemonError = nil;
                [NSUserDefaults.standardUserDefaults setObject:self.savedConfiguration forKey:@"WeeklyScheduleSavedConfiguration"];
                [self persistDraft];
            } else [self presentError:error];
            [self updateInterface]; [self fetchStatus];
        });
    }];
}
- (NSDictionary *)sharedPolicy {
    NSDictionary *draft = self.draftConfiguration;
    return @{@"blocklist":draft[@"blocklist"], @"isAllowlist":draft[@"isAllowlist"], @"blockSettings":draft[@"blockSettings"]};
}
- (void)recordSharedPolicy:(NSDictionary *)policy {
    NSMutableDictionary *saved = [self.savedConfiguration mutableCopy] ?: [@{@"slots":@[], @"enabled":@NO} mutableCopy];
    for (NSString *key in @[@"blocklist", @"isAllowlist", @"blockSettings"]) saved[key] = policy[key];
    self.savedConfiguration = saved;
    [NSUserDefaults.standardUserDefaults setObject:saved forKey:@"WeeklyScheduleSavedConfiguration"];
}
- (void)mirrorSharedPolicy:(NSDictionary *)policy {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:policy[@"blocklist"] forKey:@"Blocklist"];
    [defaults setBool:[policy[@"isAllowlist"] boolValue] forKey:@"BlockAsWhitelist"];
    [policy[@"blockSettings"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) { [defaults setObject:value forKey:key]; }];
}
- (void)restoreSharedPolicy {
    if (!self.savedConfiguration) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:self.savedConfiguration[@"blocklist"] forKey:@"Blocklist"];
    [defaults setBool:[self.savedConfiguration[@"isAllowlist"] boolValue] forKey:@"BlockAsWhitelist"];
    [self.savedConfiguration[@"blockSettings"] enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) { [defaults setObject:value forKey:key]; }];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SCConfigurationChangedNotification" object:self];
}
- (void)syncSharedPolicyIfNeededWithCompletion:(void (^)(BOOL))completion {
    if (!self.friendProtectionEnabled && !self.savedConfiguration && ![SCUIUtilities blockIsRunning]) { if (completion) completion(YES); return; }
    NSDictionary *policy = self.sharedPolicy;
    NSMutableDictionary *old = [NSMutableDictionary new];
    for (NSString *key in @[@"blocklist", @"isAllowlist", @"blockSettings"]) if (self.savedConfiguration[key]) old[key] = self.savedConfiguration[key];
    if ([policy isEqual:old]) { if (completion) completion(YES); return; }
    if (self.busy) { if (completion) completion(NO); return; }
    self.busy = YES; [self updateInterface];
    NSDictionary *baseline = self.savedConfiguration;
    [self.client getWeeklySchedule:^(NSDictionary *status, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) { self.busy = NO; [self presentError:error]; [self updateInterface]; if (completion) completion(NO); return; }
            NSMutableDictionary *rebased = [[SCWeeklySchedule sharedPolicy:policy rebasedFrom:baseline onto:status] mutableCopy];
            rebased[@"expectedBlocklist"] = status[@"blocklist"] ?: @[];
            [self mirrorSharedPolicy:[SCWeeklySchedule sharedPolicy:self.sharedPolicy rebasedFrom:policy onto:rebased]];
            [self submitSharedPolicy:rebased password:@"" completion:completion];
        });
    }];
}
- (void)submitSharedPolicy:(NSDictionary *)policy password:(NSString *)password completion:(void (^)(BOOL))completion {
    [self.client setSharedPolicy:policy friendPassword:password reply:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([error.domain isEqual:@"SelfControl.Schedule"] && error.code == 6) {
                self.busy = NO;
                [self syncSharedPolicyIfNeededWithCompletion:completion];
                return;
            }
            if ([self needsFriendPassword:error]) {
                [self requestFriendPassword:@"Removing blocked websites, allowing more websites, or weakening blocking options requires your friend's password. Existing blocking stays in effect until approval."
                    approved:^(NSString *approval) { [self submitSharedPolicy:policy password:approval completion:completion]; }
                    cancelled:^{ [self restoreSharedPolicy]; self.busy = NO; [self updateInterface]; if (completion) completion(NO); }];
                return;
            }
            if (!error) [self recordSharedPolicy:policy];
            else { [self restoreSharedPolicy]; [self presentError:error]; }
            self.busy = NO; [self updateInterface]; [self fetchStatus];
            if (completion) completion(error == nil);
            if (!error) [self syncSharedPolicyIfNeededWithCompletion:nil];
        });
    }];
}
- (void)passwordAction:(id)sender {
    if (self.friendProtectionEnabled) {
        self.busy = YES; [self updateInterface];
        [self requestFriendPassword:@"Enter your friend's current password to turn off password protection. Your Mac administrator password cannot replace it. Active blocks will still run until their end time."
            approved:^(NSString *password) {
                [self.client disableFriendPassword:password reply:^(NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.busy = NO;
                        if (!error) { self.friendProtectionEnabled = NO; [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"FriendProtectionEnabled"]; }
                        else [self presentError:error];
                        [self updateInterface]; [self fetchStatus];
                    });
                }];
            } cancelled:^{ self.busy = NO; [self updateInterface]; }];
        return;
    }
    NSAlert *alert = [NSAlert new]; alert.messageText = @"Set a friend-held password";
    alert.informativeText = @"Have your friend enter and confirm a password of at least 8 characters. You can still add restrictions freely. Reducing blocking or turning off this password will require it. There is no administrator reset.";
    NSView *fields = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 390, 72)];
    NSSecureTextField *password = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 40, 390, 28)];
    NSSecureTextField *confirm = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 390, 28)];
    password.placeholderString = @"Friend's new password"; confirm.placeholderString = @"Confirm password";
    password.accessibilityLabel = @"Friend's new password"; confirm.accessibilityLabel = @"Confirm password";
    [fields addSubview:password]; [fields addSubview:confirm]; alert.accessoryView = fields;
    [alert addButtonWithTitle:@"Set password"]; [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) { password.stringValue = @""; confirm.stringValue = @""; return; }
        NSString *secret = password.stringValue;
        BOOL matches = [secret isEqual:confirm.stringValue]; password.stringValue = @""; confirm.stringValue = @"";
        if (!matches || secret.length < 8) { [self presentError:[SCFriendProtection error:SCFriendPasswordIncorrect message:@"The passwords must match and contain at least 8 characters."]]; return; }
        self.busy = YES; [self updateInterface];
        NSDictionary *policy = self.sharedPolicy;
        [self.client installDaemon:^(NSError *installError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (installError) { self.busy = NO; [self presentError:installError]; [self updateInterface]; return; }
                [self.client refreshConnectionAndRun:^{
                    [self.client setFriendPassword:secret policy:policy reply:^(NSError *error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.busy = NO;
                            if (!error) {
                                self.friendProtectionEnabled = YES; [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"FriendProtectionEnabled"];
                                [self recordSharedPolicy:policy];
                            } else [self presentError:error];
                            [self updateInterface]; [self fetchStatus];
                        });
                    }];
                }];
            });
        }];
    }];
    [alert.window makeFirstResponder:password];
}

- (void)dealloc { [self.timer invalidate]; }
@end
