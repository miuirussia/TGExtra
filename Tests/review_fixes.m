#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "FakeLocationManager.h"
#import "Constants.h"
#import "UI/SettingsCells.h"
#import "Logger/Logger.h"

@interface TGExtraFakeLocationManager (TestDelivery)
- (void)lieToDelegates;
@end

@interface ThreadedLocationDelegate : NSObject <CLLocationManagerDelegate>
@property CLLocationManager *manager;
@property NSRunLoop *runLoop;
@property NSThread *creationThread;
@property dispatch_semaphore_t ready;
@property dispatch_semaphore_t resume;
@property dispatch_semaphore_t delivered;
@property dispatch_semaphore_t finished;
@property NSUInteger callbacks;
@property BOOL stopping;
@end
@implementation ThreadedLocationDelegate
- (void)run {
    @autoreleasepool {
        self.creationThread = NSThread.currentThread;
        self.runLoop = NSRunLoop.currentRunLoop;
        self.manager = [CLLocationManager new];
        self.manager.delegate = self;
        [TGExtraFakeLocationManager.shared registerManager:self.manager];
        NSPort *port = [NSMachPort port];
        [self.runLoop addPort:port forMode:NSDefaultRunLoopMode];
        dispatch_semaphore_signal(self.ready);
        dispatch_semaphore_wait(self.resume, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while (!self.stopping && deadline.timeIntervalSinceNow > 0) {
            [self.runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        [self.runLoop removePort:port forMode:NSDefaultRunLoopMode];
        [port invalidate];
        dispatch_semaphore_signal(self.finished);
    }
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    NSCAssert(NSThread.currentThread == self.creationThread, @"Preserve the manager's creation thread");
    NSCAssert(manager == self.manager && [locations.firstObject coordinate].latitude == 1,
              @"Deliver the selected coordinate to the original manager");
    self.callbacks++;
    dispatch_semaphore_signal(self.delivered);
}
@end

static void testLocationRunLoop(NSUserDefaults *defaults) {
    ThreadedLocationDelegate *delegate = [ThreadedLocationDelegate new];
    delegate.ready = dispatch_semaphore_create(0);
    delegate.resume = dispatch_semaphore_create(0);
    delegate.delivered = dispatch_semaphore_create(0);
    delegate.finished = dispatch_semaphore_create(0);
    NSThread *thread = [[NSThread alloc] initWithTarget:delegate selector:@selector(run) object:nil];
    [thread start];
    NSCAssert(dispatch_semaphore_wait(delegate.ready, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
              @"Create a manager with a background run loop");
    TGExtraFakeLocationManager *registry = TGExtraFakeLocationManager.shared;
    [registry registerManager:delegate.manager];
    [registry lieToDelegates];
    NSCAssert(delegate.callbacks == 0, @"Re-registration on main must not move callback delivery");

    [defaults setBool:NO forKey:FAKE_LOCATION_ENABLED_KEY];
    dispatch_semaphore_t drained = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock([delegate.runLoop getCFRunLoop], kCFRunLoopCommonModes, ^{
        dispatch_semaphore_signal(drained);
    });
    dispatch_semaphore_signal(delegate.resume);
    CFRunLoopWakeUp([delegate.runLoop getCFRunLoop]);
    NSCAssert(dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
              @"Drain queued deliveries on the background run loop");
    NSCAssert(delegate.callbacks == 0, @"Disabling the setting cancels a queued synthetic update");

    [defaults setBool:YES forKey:FAKE_LOCATION_ENABLED_KEY];
    [registry lieToDelegates];
    NSCAssert(dispatch_semaphore_wait(delegate.delivered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
              @"Wake the manager's run loop and deliver the synthetic update");
    NSCAssert(delegate.callbacks == 1, @"Deliver exactly once on the creation thread");
    CFRunLoopPerformBlock([delegate.runLoop getCFRunLoop], kCFRunLoopCommonModes, ^{
        delegate.stopping = YES;
    });
    CFRunLoopWakeUp([delegate.runLoop getCFRunLoop]);
    NSCAssert(dispatch_semaphore_wait(delegate.finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
              @"Stop the background location run loop");
}

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
    testLocationRunLoop(defaults);
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
        puts("PASS location callback run loops, queued cancellation, reentrancy/concurrency, real UIKit cell reuse and shared log read/write/clear");
    }
    return 0;
}
