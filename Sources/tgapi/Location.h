#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import "Constants.h"

// Zero is a valid coordinate; missing preferences are a separate state.
static inline BOOL TGExtraSavedCoordinate(NSUserDefaults *defaults, CLLocationCoordinate2D *coordinate) {
    NSNumber *latitude = [defaults objectForKey:FAKE_LATITUDE_KEY];
    NSNumber *longitude = [defaults objectForKey:FAKE_LONGITUDE_KEY];
    if (![latitude isKindOfClass:NSNumber.class] || ![longitude isKindOfClass:NSNumber.class]) return NO;
    CLLocationCoordinate2D value = CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
    if (!CLLocationCoordinate2DIsValid(value)) return NO;
    *coordinate = value;
    return YES;
}
