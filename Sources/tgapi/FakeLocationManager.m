#import "FakeLocationManager.h"
#import "Location.h"
#import <UIKit/UIKit.h>

@interface TGExtraFakeLocationManager ()
@property(nonatomic, strong) NSMapTable<CLLocationManager *, NSRunLoop *> *locationManagers;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation TGExtraFakeLocationManager
+ (instancetype)shared {
    static TGExtraFakeLocationManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [self new]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _locationManagers = [NSMapTable weakToStrongObjectsMapTable];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stopTimer)
            name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(startTimer)
            name:UIApplicationDidBecomeActiveNotification object:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ [self startTimer]; });
    }
    return self;
}

- (void)registerManager:(CLLocationManager *)manager {
    if (!manager) return;
    @synchronized(self.locationManagers) {
        if (![self.locationManagers objectForKey:manager]) {
            [self.locationManagers setObject:NSRunLoop.currentRunLoop forKey:manager];
        }
    }
}

- (void)startTimer {
    if (self.timer || UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    __weak TGExtraFakeLocationManager *weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:20 repeats:YES block:^(NSTimer *timer) {
        [weakSelf lieToDelegates];
    }];
}

- (void)stopTimer {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)deliverToManager:(CLLocationManager *)manager {
    if (!manager) return;
    CLLocationCoordinate2D coordinate;
    if (![NSUserDefaults.standardUserDefaults boolForKey:FAKE_LOCATION_ENABLED_KEY] ||
        !TGExtraSavedCoordinate(NSUserDefaults.standardUserDefaults, &coordinate)) return;
    NSArray *locations = @[[[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude]];
    id<CLLocationManagerDelegate> delegate = manager.delegate;
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [delegate locationManager:manager didUpdateLocations:locations];
    }
}

- (void)lieToDelegates {
    if (![NSUserDefaults.standardUserDefaults boolForKey:FAKE_LOCATION_ENABLED_KEY]) return;
    NSArray<CLLocationManager *> *managers;
    @synchronized(self.locationManagers) { managers = self.locationManagers.keyEnumerator.allObjects; }
    for (CLLocationManager *manager in managers) {
        NSRunLoop *runLoop;
        @synchronized(self.locationManagers) { runLoop = [self.locationManagers objectForKey:manager]; }
        if (!runLoop) continue;
        if ([runLoop getCFRunLoop] == CFRunLoopGetCurrent()) {
            [self deliverToManager:manager];
        } else {
            __weak CLLocationManager *weakManager = manager;
            CFRunLoopPerformBlock([runLoop getCFRunLoop], kCFRunLoopCommonModes, ^{
                [self deliverToManager:weakManager];
            });
            CFRunLoopWakeUp([runLoop getCFRunLoop]);
        }
    }
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
