#!/usr/bin/env python3
"""Exercise the settings controls on real UIKit through Mac Catalyst.

Only TGExtra content/localization and input events are stubbed. The navigation
controller and its transition delegate come from the production source.
"""
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

if sys.platform != 'darwin':
    print('SKIP UIKit settings controls: Mac Catalyst requires macOS')
    sys.exit(0)

sdk = Path(subprocess.check_output(
    ['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip())
frameworks = sdk / 'System/iOSSupport/System/Library/Frameworks'
if not (frameworks / 'UIKit.framework/Headers/UIKit.h').exists():
    print('SKIP UIKit settings controls: set DEVELOPER_DIR to an Xcode installation with Mac Catalyst')
    sys.exit(0)

ROOT = Path(__file__).resolve().parent.parent
source = (ROOT / 'Sources/tgapi/UI/SettingsNavigation.m').read_text()
stubs = '''#import <UIKit/UIKit.h>
@interface TGExtra : UIViewController @end
@implementation TGExtra @end
@interface TGExtraLocalization : NSObject
+ (NSString *)localizedStringForKey:(NSString *)key;
@end
@implementation TGExtraLocalization
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end
'''
source = source.replace('#import "SettingsNavigation.h"', '').replace('#import "Headers.h"', stubs)
tests = r'''
@interface PresenterProbe : UIViewController
@property(nonatomic) NSUInteger closes;
@end
@implementation PresenterProbe
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    self.closes++;
    if (completion) completion();
}
@end
@interface NavigationProbe : TGExtraSettingsNavigationController
@property(nonatomic, strong) PresenterProbe *presenter;
@end
@implementation NavigationProbe
- (UIViewController *)presentingViewController { return self.presenter; }
@end
@interface GestureProbe : UIScreenEdgePanGestureRecognizer
@property(nonatomic) UIGestureRecognizerState testState;
@property(nonatomic) CGPoint translation;
@property(nonatomic) CGPoint velocity;
@end
@implementation GestureProbe
- (UIGestureRecognizerState)state { return self.testState; }
- (CGPoint)translationInView:(UIView *)view { return self.translation; }
- (CGPoint)velocityInView:(UIView *)view { return self.velocity; }
@end
@interface InteractionProbe : UIPercentDrivenInteractiveTransition
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) CGFloat progress;
@end
@implementation InteractionProbe
- (void)updateInteractiveTransition:(CGFloat)progress { self.progress = progress; }
- (void)finishInteractiveTransition { self.finished = YES; }
- (void)cancelInteractiveTransition { self.cancelled = YES; }
@end
int main(void) {
    @autoreleasepool {
        // UIKit can load the navigation view before a root is installed.
        NavigationProbe *navigation = [NavigationProbe new];
        [navigation loadViewIfNeeded];
        TGExtra *settings = [TGExtra new];
        [navigation setViewControllers:@[settings] animated:NO];
        navigation.presenter = [PresenterProbe new];
        navigation.settingsTransition = [TGExtraSettingsTransition new];
        navigation.transitioningDelegate = navigation.settingsTransition;
        [navigation viewWillAppear:NO];
        UIBarButtonItem *back = settings.navigationItem.leftBarButtonItem;
        NSCAssert(back && back.target == navigation && back.action, @"Back button survives early view loading");
        void (*action)(id, SEL) = (void (*)(id, SEL))[back.target methodForSelector:back.action];
        action(back.target, back.action);
        NSCAssert(navigation.presenter.closes == 1, @"Back button dismisses through its presenter");
        NSCAssert(!navigation.interactivePopGestureRecognizer.enabled, @"Disable the competing root pop gesture");
        GestureProbe *gesture = [GestureProbe new];
        NSCAssert([navigation gestureRecognizerShouldBegin:gesture], @"Root edge swipe is available");
        gesture.testState = UIGestureRecognizerStateBegan;
        [navigation swipeBack:gesture];
        NSCAssert(navigation.presenter.closes == 2, @"Swipe starts dismissal through its presenter");
        NSCAssert(navigation.settingsTransition.backTransition != nil, @"Interactive dismissal exists before dismissing");
        NSCAssert([navigation.settingsTransition interactionControllerForDismissal:navigation.settingsTransition] == navigation.settingsTransition.backTransition, @"UIKit receives interactive dismissal");
        navigation.view.frame = CGRectMake(0, 0, 400, 800);
        InteractionProbe *interaction = [InteractionProbe new];
        navigation.settingsTransition.backTransition = interaction;
        gesture.testState = UIGestureRecognizerStateChanged;
        gesture.translation = CGPointMake(100, 0);
        [navigation swipeBack:gesture];
        NSCAssert(fabs(interaction.progress - 0.25) < 0.001, @"Swipe progress follows the finger");
        gesture.testState = UIGestureRecognizerStateEnded;
        [navigation swipeBack:gesture];
        NSCAssert(interaction.cancelled && !interaction.finished, @"Short swipe returns to settings");
        NSCAssert(navigation.settingsTransition.backTransition == interaction, @"Keep interaction alive during cancellation");
        interaction = [InteractionProbe new];
        navigation.settingsTransition.backTransition = interaction;
        gesture.translation = CGPointMake(200, 0);
        [navigation swipeBack:gesture];
        NSCAssert(interaction.finished && !interaction.cancelled, @"Long swipe finishes returning");
        interaction = [InteractionProbe new];
        navigation.settingsTransition.backTransition = interaction;
        gesture.translation = CGPointMake(20, 0);
        gesture.velocity = CGPointMake(700, 0);
        [navigation swipeBack:gesture];
        NSCAssert(interaction.finished, @"Fast swipe finishes returning");
        interaction = [InteractionProbe new];
        navigation.settingsTransition.backTransition = interaction;
        gesture.testState = UIGestureRecognizerStateCancelled;
        [navigation swipeBack:gesture];
        NSCAssert(interaction.cancelled, @"Interrupted gesture cancels safely");
        puts("PASS UIKit settings back button, early view loading, gesture conflict, swipe progress, finish and cancellation");
    }
    return 0;
}
'''
with tempfile.TemporaryDirectory(prefix='tgextra-navigation-') as tmp:
    harness = Path(tmp) / 'controls.m'
    harness.write_text(source + tests)
    binary = Path(tmp) / 'controls'
    subprocess.run([
        'xcrun', 'clang', '-target', f'{platform.machine()}-apple-ios15.0-macabi',
        '-isysroot', str(sdk), '-iframework', str(frameworks),
        '-fobjc-arc', '-Werror', '-Wno-deprecated-declarations',
        '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'CoreGraphics',
        str(harness), '-o', str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
