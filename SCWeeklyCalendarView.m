#import "SCWeeklyCalendarView.h"
#import "SCWeeklySchedule.h"

static CGFloat const SCTimeGutter = 54;
static CGFloat const SCDayHeader = 32;

static NSColor *SCWeeklyAccent(void) {
    if (@available(macOS 10.14, *)) return NSColor.controlAccentColor;
    return NSColor.selectedControlColor;
}
static NSColor *SCWeeklySeparator(void) {
    if (@available(macOS 10.14, *)) return NSColor.separatorColor;
    return NSColor.gridColor;
}

@interface SCWeeklyCalendarView ()
@property NSIndexSet *dragBaseline;
@property NSInteger dragDay;
@property NSInteger dragRow;
@property BOOL erasing;
@property NSUInteger focusedSlot;
@end

@implementation SCWeeklyCalendarView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _selectedSlots = NSIndexSet.indexSet;
        _editable = YES;
        _focusedSlot = 18;
        self.accessibilityRole = NSAccessibilityGroupRole;
        self.accessibilityLabel = @"Weekly blocking calendar";
        self.accessibilityHelp = @"Drag to add or erase half-hour periods. Arrow keys move between times; Space toggles a time. The Add time controls also select a precise range.";
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (BOOL)acceptsFirstResponder { return self.editable; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return YES; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return YES; }
- (CGFloat)rowHeight { return MAX(1, (NSHeight(self.bounds) - SCDayHeader - 16) / 48); }
- (CGFloat)dayWidth { return (NSWidth(self.bounds) - SCTimeGutter) / 7; }
- (void)setSelectedSlots:(NSIndexSet *)slots {
    _selectedSlots = [slots copy];
    self.needsDisplay = YES;
    [self updateAccessibilityValue];
}
- (void)setEditable:(BOOL)editable { _editable = editable; self.needsDisplay = YES; }
- (NSString *)timeAtRow:(NSUInteger)row { return [NSString stringWithFormat:@"%02lu:%02lu", row / 2, (row % 2) * 30]; }
- (void)updateAccessibilityValue {
    NSArray *days = @[@"Monday", @"Tuesday", @"Wednesday", @"Thursday", @"Friday", @"Saturday", @"Sunday"];
    NSUInteger row = self.focusedSlot % 48;
    self.accessibilityValue = [NSString stringWithFormat:@"%@ %@ to %@, %@. %lu half-hour periods selected.",
        days[self.focusedSlot / 48], [self timeAtRow:row], [self timeAtRow:row + 1],
        [self.selectedSlots containsIndex:self.focusedSlot] ? @"blocked" : @"open", self.selectedSlots.count];
}
- (void)drawText:(NSString *)text frame:(NSRect)frame font:(NSFont *)font color:(NSColor *)color centered:(BOOL)centered {
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = centered ? NSTextAlignmentCenter : NSTextAlignmentLeft;
    [text drawInRect:frame withAttributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:color, NSParagraphStyleAttributeName:style}];
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.controlBackgroundColor setFill]; NSRectFill(self.bounds);
    CGFloat rowHeight = self.rowHeight, dayWidth = self.dayWidth;
    NSArray *days = @[@"Monday", @"Tuesday", @"Wednesday", @"Thursday", @"Friday", @"Saturday", @"Sunday"];
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSUInteger now = [SCWeeklySchedule slotAtDate:NSDate.date calendar:calendar];
    for (NSUInteger day = 0; day < 7; day++) {
        CGFloat x = SCTimeGutter + day * dayWidth;
        if (day >= 5) {
            [[NSColor.labelColor colorWithAlphaComponent:0.025] setFill];
            NSRectFill(NSMakeRect(x, SCDayHeader, dayWidth, 48 * rowHeight));
        }
        [self drawText:days[day] frame:NSMakeRect(x, 7, dayWidth, 20) font:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
            color:day == now / 48 ? SCWeeklyAccent() : NSColor.labelColor centered:YES];
        NSUInteger row = 0;
        while (row < 48) {
            if (![self.selectedSlots containsIndex:day * 48 + row]) { row++; continue; }
            NSUInteger start = row;
            while (row < 48 && [self.selectedSlots containsIndex:day * 48 + row]) row++;
            NSRect block = NSMakeRect(x + 3, SCDayHeader + start * rowHeight + 1, dayWidth - 6, (row - start) * rowHeight - 2);
            [[SCWeeklyAccent() colorWithAlphaComponent:self.editable ? 0.22 : 0.14] setFill];
            [[NSBezierPath bezierPathWithRoundedRect:block xRadius:4 yRadius:4] fill];
            [SCWeeklyAccent() setFill]; NSRectFill(NSMakeRect(block.origin.x, block.origin.y + 2, 3, MAX(1, block.size.height - 4)));
            if (block.size.height >= 18) {
                NSString *time = [NSString stringWithFormat:@"%@–%@", [self timeAtRow:start], [self timeAtRow:row]];
                [self drawText:time frame:NSMakeRect(x + 10, block.origin.y + 3, dayWidth - 14, 16)
                    font:[NSFont systemFontOfSize:10 weight:NSFontWeightMedium] color:NSColor.labelColor centered:NO];
            }
        }
    }
    for (NSUInteger hour = 0; hour <= 24; hour++) {
        CGFloat y = SCDayHeader + hour * 2 * rowHeight;
        [[SCWeeklySeparator() colorWithAlphaComponent:0.65] setStroke];
        NSBezierPath *line = NSBezierPath.bezierPath;
        [line moveToPoint:NSMakePoint(SCTimeGutter, y)]; [line lineToPoint:NSMakePoint(NSWidth(self.bounds), y)]; [line stroke];
        [self drawText:[NSString stringWithFormat:@"%02lu:00", hour] frame:NSMakeRect(3, y - 6, 46, 14)
            font:[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular] color:NSColor.secondaryLabelColor centered:NO];
        if (hour < 24) {
            [[SCWeeklySeparator() colorWithAlphaComponent:0.25] setStroke];
            NSBezierPath *half = NSBezierPath.bezierPath;
            [half moveToPoint:NSMakePoint(SCTimeGutter, y + rowHeight)]; [half lineToPoint:NSMakePoint(NSWidth(self.bounds), y + rowHeight)]; [half stroke];
        }
    }
    [SCWeeklySeparator() setStroke];
    for (NSUInteger day = 0; day <= 7; day++) {
        NSBezierPath *line = NSBezierPath.bezierPath;
        CGFloat x = SCTimeGutter + day * dayWidth;
        [line moveToPoint:NSMakePoint(x, SCDayHeader)]; [line lineToPoint:NSMakePoint(x, SCDayHeader + 48 * rowHeight)]; [line stroke];
    }
    NSDateComponents *time = [calendar components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:NSDate.date];
    CGFloat nowY = SCDayHeader + (time.hour * 2 + time.minute / 30.0) * rowHeight;
    [NSColor.systemRedColor setStroke];
    NSBezierPath *nowLine = NSBezierPath.bezierPath;
    [nowLine moveToPoint:NSMakePoint(SCTimeGutter + (now / 48) * dayWidth, nowY)];
    [nowLine lineToPoint:NSMakePoint(SCTimeGutter + (now / 48 + 1) * dayWidth, nowY)]; [nowLine stroke];
    if (self.window.firstResponder == self && self.editable) {
        [NSColor.keyboardFocusIndicatorColor setStroke];
        NSBezierPath *focus = [NSBezierPath bezierPathWithRect:NSMakeRect(SCTimeGutter + self.focusedSlot / 48 * dayWidth + 1,
            SCDayHeader + self.focusedSlot % 48 * rowHeight + 1, dayWidth - 2, rowHeight - 2)];
        focus.lineWidth = 2; [focus stroke];
    }
}
- (void)replaceSelection:(NSIndexSet *)selection notify:(BOOL)notify {
    if (!self.editable) return;
    if ([self.selectedSlots isEqual:selection]) return;
    NSIndexSet *old = self.selectedSlots;
    [[self.undoManager prepareWithInvocationTarget:self] replaceSelection:old notify:YES];
    [self.undoManager setActionName:@"Change blocking times"];
    self.selectedSlots = selection;
    if (notify && self.selectionChanged) self.selectionChanged();
}
- (void)addDay:(NSUInteger)day fromSlot:(NSUInteger)start toSlot:(NSUInteger)end {
    if (!self.editable || day > 6 || start >= end || end > 48) return;
    NSMutableIndexSet *slots = [self.selectedSlots mutableCopy];
    [slots addIndexesInRange:NSMakeRange(day * 48 + start, end - start)];
    [self replaceSelection:slots notify:YES];
}
- (void)clearSelection { if (self.editable) [self replaceSelection:NSIndexSet.indexSet notify:YES]; }
- (void)mouseDown:(NSEvent *)event {
    if (!self.editable) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (p.x < SCTimeGutter || p.y < SCDayHeader || p.y >= SCDayHeader + 48 * self.rowHeight) return;
    [self.window makeFirstResponder:self];
    self.dragDay = MIN(6, (NSInteger)((p.x - SCTimeGutter) / self.dayWidth));
    self.dragRow = MIN(47, (NSInteger)((p.y - SCDayHeader) / self.rowHeight));
    self.focusedSlot = self.dragDay * 48 + self.dragRow;
    self.dragBaseline = self.selectedSlots;
    self.erasing = [self.selectedSlots containsIndex:self.focusedSlot];
    [self mouseDragged:event];
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.dragBaseline || !self.editable) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger day = MAX(0, MIN(6, (NSInteger)floor((p.x - SCTimeGutter) / self.dayWidth)));
    NSInteger row = MAX(0, MIN(47, (NSInteger)floor((p.y - SCDayHeader) / self.rowHeight)));
    NSMutableIndexSet *slots = [self.dragBaseline mutableCopy];
    for (NSInteger d = MIN(day, self.dragDay); d <= MAX(day, self.dragDay); d++) {
        NSRange range = NSMakeRange(d * 48 + MIN(row, self.dragRow), labs(row - self.dragRow) + 1);
        if (self.erasing) [slots removeIndexesInRange:range]; else [slots addIndexesInRange:range];
    }
    self.selectedSlots = slots;
}
- (void)mouseUp:(NSEvent *)event {
    if (!self.dragBaseline) return;
    NSIndexSet *selection = self.selectedSlots, *old = self.dragBaseline;
    self.dragBaseline = nil;
    _selectedSlots = old;
    [self replaceSelection:selection notify:YES];
}
- (void)keyDown:(NSEvent *)event {
    if (!self.editable) return;
    NSInteger slot = self.focusedSlot;
    switch (event.keyCode) {
        case 123: slot -= 48; break;
        case 124: slot += 48; break;
        case 125: slot += 1; break;
        case 126: slot -= 1; break;
        case 49: {
            NSMutableIndexSet *slots = [self.selectedSlots mutableCopy];
            if ([slots containsIndex:slot]) [slots removeIndex:slot]; else [slots addIndex:slot];
            [self replaceSelection:slots notify:YES]; return;
        }
        default: [super keyDown:event]; return;
    }
    self.focusedSlot = MAX(0, MIN(335, slot));
    [self updateAccessibilityValue];
    self.needsDisplay = YES;
}
@end
