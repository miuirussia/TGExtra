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

// Returns the path to TGExtra.bundle regardless of installation method.
// Works on jailbreak, SwiftGram, AltStore, and any sideloaded IPA.
// Both TGExtraLocalization and LanguageSelector must use this function.
NSString *TGExtraBundlePath(void);

// Defined in UIHooks.xm, which Theos compiles as Objective-C++. Without this
// the names come out mangled and plain .m callers fail to link.
#ifdef __cplusplus
extern "C" {
#endif

// Brief message floating above the bottom of the key window. Safe to call from
// any thread; it hops to main itself.
void TGExtraShowToast(NSString *text);

// Opens a tg:// link inside *this* app.
//
// -[UIApplication openURL:] hands the scheme to whichever app iOS has it
// registered to, which on a device with official Telegram installed means the
// link leaves the fork the tweak is running in. Handing the URL straight to
// this app's own delegate keeps it here.
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
