#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface TGExtraFakeLocationManager : NSObject
+ (instancetype)shared;
// Register on the manager's creation thread; later registrations preserve its run loop.
- (void)registerManager:(CLLocationManager *)manager;
@end
