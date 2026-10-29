#import "SettingsNavigation.h"
#import "Headers.h"

@interface TGExtraSettingsTransition : NSObject
    <UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning>
@property(nonatomic) BOOL opening;
@property(nonatomic, strong) UIPercentDrivenInteractiveTransition *backTransition;
@end

@interface TGExtraSettingsNavigationController : UINavigationController <UIGestureRecognizerDelegate>
@property(nonatomic, strong) TGExtraSettingsTransition *settingsTransition;
@end

@implementation TGExtraSettingsNavigationController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.interactivePopGestureRecognizer.enabled = NO;
    UIScreenEdgePanGestureRecognizer *gesture = [[UIScreenEdgePanGestureRecognizer alloc]
        initWithTarget:self action:@selector(swipeBack:)];
    gesture.edges = UIRectEdgeLeft;
    gesture.delegate = self;
    [self.view addGestureRecognizer:gesture];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UIBarButtonItem *back = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.left"]
        style:UIBarButtonItemStylePlain target:self action:@selector(closeSettings)];
    back.accessibilityLabel = [TGExtraLocalization localizedStringForKey:@"CLOSE"];
    self.viewControllers.firstObject.navigationItem.leftBarButtonItem = back;
}

- (void)closeSettings {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return self.viewControllers.count == 1 && !self.presentedViewController &&
        !self.isBeingPresented && !self.isBeingDismissed;
}

- (void)swipeBack:(UIScreenEdgePanGestureRecognizer *)gesture {
    CGFloat width = MAX(1.0, self.view.bounds.size.width);
    CGFloat progress = MAX(0.0, MIN(1.0, [gesture translationInView:self.view].x / width));
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            self.settingsTransition.backTransition = [UIPercentDrivenInteractiveTransition new];
            [self closeSettings];
            break;
        case UIGestureRecognizerStateChanged:
            [self.settingsTransition.backTransition updateInteractiveTransition:progress];
            break;
        case UIGestureRecognizerStateEnded:
            if (progress > 0.4 || [gesture velocityInView:self.view].x > 600.0) {
                [self.settingsTransition.backTransition finishInteractiveTransition];
            } else {
                [self.settingsTransition.backTransition cancelInteractiveTransition];
            }
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self.settingsTransition.backTransition cancelInteractiveTransition];
            break;
        default:
            break;
    }
}
@end

@implementation TGExtraSettingsTransition
- (id<UIViewControllerAnimatedTransitioning>)animationControllerForPresentedController:(UIViewController *)presented
    presentingController:(UIViewController *)presenting sourceController:(UIViewController *)source {
    self.opening = YES;
    return self;
}

- (id<UIViewControllerAnimatedTransitioning>)animationControllerForDismissedController:(UIViewController *)dismissed {
    self.opening = NO;
    return self;
}

- (id<UIViewControllerInteractiveTransitioning>)interactionControllerForDismissal:
    (id<UIViewControllerAnimatedTransitioning>)animator {
    return self.backTransition;
}

- (NSTimeInterval)transitionDuration:(id<UIViewControllerContextTransitioning>)context {
    return UIAccessibilityIsReduceMotionEnabled() ? 0.2 : 0.35;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
    UIView *container = context.containerView;
    UIView *from = [context viewForKey:UITransitionContextFromViewKey];
    UIView *to = [context viewForKey:UITransitionContextToViewKey];
    UIViewController *destination = [context viewControllerForKey:UITransitionContextToViewControllerKey];
    to.frame = [context finalFrameForViewController:destination];
    BOOL opening = self.opening;
    BOOL reducedMotion = UIAccessibilityIsReduceMotionEnabled();
    CGFloat width = container.bounds.size.width;
    if (opening) {
        [container addSubview:to];
        if (reducedMotion) to.alpha = 0.0;
        else to.transform = CGAffineTransformMakeTranslation(width, 0.0);
    } else {
        [container insertSubview:to belowSubview:from];
        if (!reducedMotion) to.transform = CGAffineTransformMakeTranslation(-width * 0.3, 0.0);
    }
    [UIView animateWithDuration:[self transitionDuration:context] delay:0.0
        options:UIViewAnimationOptionCurveEaseInOut animations:^{
            to.alpha = 1.0;
            to.transform = CGAffineTransformIdentity;
            if (reducedMotion) from.alpha = opening ? 1.0 : 0.0;
            else from.transform = CGAffineTransformMakeTranslation(opening ? -width * 0.3 : width, 0.0);
        } completion:^(BOOL finished) {
            [context completeTransition:!context.transitionWasCancelled];
            from.transform = CGAffineTransformIdentity;
            to.transform = CGAffineTransformIdentity;
            from.alpha = 1.0;
            to.alpha = 1.0;
            self.backTransition = nil;
        }];
}
@end

void TGExtraShowSettings(void) {
    UIViewController *presenter = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    if (!presenter || presenter.isBeingDismissed || presenter.isBeingPresented) return;
    if ([presenter isKindOfClass:UINavigationController.class] &&
        [((UINavigationController *)presenter).viewControllers.firstObject isKindOfClass:TGExtra.class]) return;
    TGExtraSettingsNavigationController *navigation = [[TGExtraSettingsNavigationController alloc]
        initWithRootViewController:[TGExtra new]];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    navigation.settingsTransition = [TGExtraSettingsTransition new];
    navigation.transitioningDelegate = navigation.settingsTransition;
    [presenter presentViewController:navigation animated:YES completion:nil];
}
