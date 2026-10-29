#import "FakeLocationManager.h"
#import "Location.h"
#import <UIKit/UIKit.h>

@interface TGExtraFakeLocationManager ()
@property(nonatomic, strong) NSHashTable<CLLocationManager *> *locationManagers;
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
        _locationManagers = [NSHashTable weakObjectsHashTable];
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
    @synchronized(self.locationManagers) { [self.locationManagers addObject:manager]; }
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

- (void)lieToDelegates {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self lieToDelegates]; });
        return;
    }
    CLLocationCoordinate2D coordinate;
    if (![NSUserDefaults.standardUserDefaults boolForKey:FAKE_LOCATION_ENABLED_KEY] ||
        !TGExtraSavedCoordinate(NSUserDefaults.standardUserDefaults, &coordinate)) return;
    NSArray *locations = @[[[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude]];
    NSArray<CLLocationManager *> *managers;
    @synchronized(self.locationManagers) { managers = self.locationManagers.allObjects; }
    for (CLLocationManager *manager in managers) {
        id<CLLocationManagerDelegate> delegate = manager.delegate;
        if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [delegate locationManager:manager didUpdateLocations:locations];
        }
    }
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
