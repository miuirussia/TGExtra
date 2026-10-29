#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <roothide.h>
#import "../Constants.h"

@interface TGExtra : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface TGLocalization : NSObject
- (NSString *)get:(NSString *)queryString;
- (id)initWithVersion:(int)a code:(id)b dict:(id)c isActive:(BOOL)d;
@end

@interface TGExtraLocalization  : NSObject
@property (nonatomic, strong ) TGLocalization *localization;
@property (nonatomic, copy, readonly) NSString *languageCode;
+ (instancetype)shared;
+ (NSString *)localizedStringForKey:(NSString *)key;
@end

NSString *TGExtraBundlePath(void);

#ifdef __cplusplus
extern "C" {
#endif

void TGExtraShowToast(NSString *text);

void TGExtraOpenTelegramURL(NSURL *url);

#ifdef __cplusplus
}
#endif

@interface LanguageSelector : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface LocationSelector : UIViewController <MKMapViewDelegate>
@end

@interface ThreeFingerGestureHandler : NSObject
- (void)handleThreeFingerLongPress:(UILongPressGestureRecognizer *)gesture;
@end
