#import <Cocoa/Cocoa.h>

@interface SCWeeklyCalendarView : NSView
@property (nonatomic, copy) NSIndexSet *selectedSlots;
@property (nonatomic) BOOL editable;
@property (copy) void (^selectionChanged)(void);
- (void)addDay:(NSUInteger)day fromSlot:(NSUInteger)start toSlot:(NSUInteger)end;
- (void)clearSelection;
@end
