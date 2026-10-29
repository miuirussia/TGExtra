#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "FakeLocationManager.h"
#import "Constants.h"
#import "UI/SettingsCells.h"
#import "Logger/Logger.h"

@interface TGExtraFakeLocationManager (TestDelivery)
- (void)lieToDelegates;
@end

@interface RegisteringLocationDelegate : NSObject <CLLocationManagerDelegate>
@property(nonatomic, strong) NSMutableArray<CLLocationManager *> *created;
@property(nonatomic) NSUInteger callbacks;
@end
@implementation RegisteringLocationDelegate
- (instancetype)init { if ((self = [super init])) _created = [NSMutableArray new]; return self; }
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    NSCAssert(NSThread.isMainThread, @"Location callbacks run on main");
    self.callbacks++;
    CLLocationManager *next = [CLLocationManager new];
    [self.created addObject:next];
    [TGExtraFakeLocationManager.shared registerManager:next];
}
@end

static void testLocationRegistry(void) {
    NSString *suite = [@"TGExtraReview-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    Method method = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
    IMP previous = method_setImplementation(method, imp_implementationWithBlock(^id(id cls) { return defaults; }));
    [defaults setBool:YES forKey:FAKE_LOCATION_ENABLED_KEY];
    [defaults setDouble:1 forKey:FAKE_LATITUDE_KEY];
    [defaults setDouble:2 forKey:FAKE_LONGITUDE_KEY];
    RegisteringLocationDelegate *delegate = [RegisteringLocationDelegate new];
    CLLocationManager *first = [CLLocationManager new], *second = [CLLocationManager new];
    first.delegate = delegate;
    second.delegate = delegate;
    TGExtraFakeLocationManager *registry = TGExtraFakeLocationManager.shared;
    [registry registerManager:first];
    [registry registerManager:second];
    [registry lieToDelegates];
    NSCAssert(delegate.callbacks == 2, @"A callback can register another manager without invalidating enumeration");
    dispatch_apply(100, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
        CLLocationManager *manager = [CLLocationManager new];
        [registry registerManager:manager];
    });
    [registry lieToDelegates];
    NSCAssert(delegate.callbacks == 4, @"Concurrent registration preserves existing weak members");
    [defaults removePersistentDomainForName:suite];
    method_setImplementation(method, previous);
}

static void testCellReset(void) {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"normalCell"];
    cell.accessoryView = [UIActivityIndicatorView new];
    cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
    cell.alpha = 0.2;
    cell.accessibilityLabel = @"stale debug log";
    cell.accessibilityHint = @"stale hint";
    cell.accessibilityValue = @"stale value";
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    cell.imageView.layer.cornerRadius = 8;
    cell.imageView.layer.masksToBounds = YES;
    TGExtraResetSettingsCell(cell);
    cell.textLabel.text = @"Location";
    NSCAssert(cell.accessoryView == nil && cell.accessoryType == UITableViewCellAccessoryNone, @"No stale spinner or disclosure");
    NSCAssert(cell.selectionStyle == UITableViewCellSelectionStyleDefault && cell.userInteractionEnabled && cell.alpha == 1, @"Restore interaction");
    NSCAssert(![cell.accessibilityLabel containsString:@"stale"] && cell.accessibilityHint == nil && cell.accessibilityValue == nil, @"Restore accessibility content");
    NSCAssert(cell.accessibilityTraits == UIAccessibilityTraitNone && cell.imageView.layer.cornerRadius == 0 && !cell.imageView.layer.masksToBounds, @"Restore traits and image style");
}

static void testLog(void) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [directory stringByAppendingPathComponent:@"Debug.log"];
    setenv("TGEXTRA_TEST_LOG_PATH", path.UTF8String, 1);
    dispatch_apply(100, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t index) {
        customLog(@"first-%zu", index);
        customLog2(@"second-%zu", index);
    });
    NSString *text = TGExtraReadLog();
    for (NSUInteger i = 0; i < 100; i++) {
        NSCAssert(([text containsString:[NSString stringWithFormat:@"first-%lu\n", (unsigned long)i]]), @"First logger writes complete lines");
        NSCAssert(([text containsString:[NSString stringWithFormat:@"second-%lu\n", (unsigned long)i]]), @"Second logger shares the same file and queue");
    }
    TGExtraClearLog();
    NSCAssert(TGExtraReadLog().length == 0 && [NSData dataWithContentsOfFile:path].length == 0, @"Clear affects the exact file used by both writers");
    customLog2(@"after clear");
    NSCAssert([TGExtraReadLog() containsString:@"after clear"], @"Logging resumes after clear");
    [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
}

int main(void) {
    @autoreleasepool {
        testLocationRegistry();
        testCellReset();
        testLog();
        puts("PASS location callback reentrancy/concurrency, real UIKit cell reuse and shared log read/write/clear");
    }
    return 0;
}
