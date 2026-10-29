#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface TGExtraFakeLocationManager : NSObject
+ (instancetype)shared;
- (void)registerManager:(CLLocationManager *)manager;
@end
