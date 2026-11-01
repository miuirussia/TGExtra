#import "Headers.h"
#import "Location.h"
#import "FakeLocationManager.h"
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>
#import<MapKit/MapKit.h>

bool shouldFakeLocation() {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	return [defaults boolForKey:FAKE_LOCATION_ENABLED_KEY];
}

%hook DeviceLocationManager

- (void)locationManager:(id)manager didUpdateLocations:(id)locations {
    CLLocationCoordinate2D coordinate;
    if (shouldFakeLocation() && TGExtraSavedCoordinate(NSUserDefaults.standardUserDefaults, &coordinate)) {
        CLLocation *location = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
        %orig(manager, @[location]);
        return;
    }
    %orig;
}

%end

%hook MKCoreLocationProvider

- (void)locationManager:(id)manager didUpdateLocations:(id)locations {
    CLLocationCoordinate2D coordinate;
    if (shouldFakeLocation() && TGExtraSavedCoordinate(NSUserDefaults.standardUserDefaults, &coordinate)) {
        CLLocation *location = [[CLLocation alloc] initWithLatitude:coordinate.latitude longitude:coordinate.longitude];
        %orig(manager, @[location]);
        return;
    }
    %orig;
}

%end

%hook CLLocationManager

- (id)init {
    self = %orig;
    if (self) {
        [[TGExtraFakeLocationManager shared] registerManager:self];
    }
    return self;
}

- (void)setDelegate:(id)delegate {
    %orig;

    [[TGExtraFakeLocationManager shared] registerManager:self];
}

%end

@interface MKCoreLocationProvider : NSObject
- (id)_clLocationManager;
@end

%hook MKCoreLocationProvider

- (id)initWithCLLocationManager:(id)locationManager {
    self = %orig;
    if (!self) return nil;
    if ([locationManager isKindOfClass:[CLLocationManager class]]) {
        [[TGExtraFakeLocationManager shared] registerManager:locationManager];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CLLocationManager *innerLocationManager = [self _clLocationManager];
		[[TGExtraFakeLocationManager shared] registerManager:innerLocationManager];
    });

    return self;
}

%end

__attribute__((constructor))
static void initLocationHooks() {
	 %init(
	    DeviceLocationManager = objc_getClass("DeviceLocationManager.DeviceLocationManager")
	);

	[TGExtraFakeLocationManager shared];
}
