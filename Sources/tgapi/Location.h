#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <math.h>
#import "Constants.h"

static inline BOOL TGExtraParseCoordinateComponent(NSString *text, double *value) {
    NSString *normalized = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"," withString:@"."];
    if (!normalized.length || [normalized rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789.+-"] invertedSet]].location != NSNotFound) return NO;
    NSScanner *scanner = [NSScanner scannerWithString:normalized];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [scanner scanDouble:value] && scanner.isAtEnd && isfinite(*value);
}

static inline BOOL TGExtraParseCoordinate(NSString *latitude, NSString *longitude, CLLocationCoordinate2D *coordinate) {
    double lat, lon;
    if (!TGExtraParseCoordinateComponent(latitude, &lat) ||
        !TGExtraParseCoordinateComponent(longitude, &lon)) return NO;
    CLLocationCoordinate2D value = CLLocationCoordinate2DMake(lat, lon);
    if (!CLLocationCoordinate2DIsValid(value)) return NO;
    *coordinate = value;
    return YES;
}

static inline BOOL TGExtraSavedCoordinate(NSUserDefaults *defaults, CLLocationCoordinate2D *coordinate) {
    NSNumber *latitude = [defaults objectForKey:FAKE_LATITUDE_KEY];
    NSNumber *longitude = [defaults objectForKey:FAKE_LONGITUDE_KEY];
    if (![latitude isKindOfClass:NSNumber.class] || ![longitude isKindOfClass:NSNumber.class]) return NO;
    CLLocationCoordinate2D value = CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue);
    if (!CLLocationCoordinate2DIsValid(value)) return NO;
    *coordinate = value;
    return YES;
}
