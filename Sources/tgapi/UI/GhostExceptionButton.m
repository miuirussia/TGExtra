#import "Headers.h"
#import "HostDisplayNode.h"
#import "ProfileBridge.h"
#import "../GhostExceptions.h"
#import "../PeerInfoStore.h"
#import "../Logger/Logger.h"
#define TGExtraLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

#define kTGExtraGhostExceptionButtonTag 9977

static const void *kTGExtraGhostPeerIdKey = &kTGExtraGhostPeerIdKey;
static const void *kTGExtraGhostNodeBoxKey = &kTGExtraGhostNodeBoxKey;

@interface TGExtraWeakBox : NSObject
@property (nonatomic, weak) id object;
@end
@implementation TGExtraWeakBox
@end

static void updateGhostExceptionButtonAppearance(UIButton *button, BOOL isException) {
    UIImage *icon = [UIImage systemImageNamed:isException ? @"eye.fill" : @"eye.slash.fill"];
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:16
                                                        weight:UIImageSymbolWeightSemibold];
    if (cfg && icon) icon = [icon imageByApplyingSymbolConfiguration:cfg];
    [button setImage:icon forState:UIControlStateNormal];
    button.accessibilityLabel = TGExtraLoc(@"GHOST_EXCEPTIONS_SECTION_HEADER");
    button.accessibilityValue = TGExtraLoc(isException ? @"GHOST_EXCEPTION_ADDED_TOAST" : @"GHOST_EXCEPTION_REMOVED_TOAST");
    button.tintColor = isException ? [UIColor systemGreenColor] : [UIColor systemGrayColor];
}

@interface TGExtraGhostExceptionButtonTarget : NSObject
+ (instancetype)shared;
@end

@implementation TGExtraGhostExceptionButtonTarget

+ (instancetype)shared {
    static TGExtraGhostExceptionButtonTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    NSNumber *peerId = objc_getAssociatedObject(sender, kTGExtraGhostPeerIdKey);
    if (!peerId || peerId.longLongValue == 0) return;

    BOOL wasException = [TGExtraGhostExceptions containsPeerId:peerId.longLongValue];

    if (wasException) {
        [TGExtraGhostExceptions removePeerId:peerId.longLongValue];
        tgextraDiag("exception REMOVE peer=%{public}@", peerId);
        TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"GHOST_EXCEPTION_REMOVED_TOAST"]);
    } else {
        NSString *name = nil;
        NSString *username = nil;
        TGExtraWeakBox *box = objc_getAssociatedObject(sender, kTGExtraGhostNodeBoxKey);
        if (box.object) {
            @try {
                NSDictionary *info = [TGExtraProfileBridge getPeerDisplayInfoFromNode:box.object];
                name = info[@"name"];
                username = info[@"username"];
            } @catch (NSException *e) {}
        }

        if (!name.length && !username.length) {
            @try {
                NSDictionary *cached = [TGExtraPeerInfoStore cachedPeerInfoForId:peerId];
                name = cached[@"name"];
                username = cached[@"username"];
            } @catch (NSException *e) {}
        }

        [TGExtraGhostExceptions addPeerId:peerId.longLongValue name:name username:username];
        tgextraDiag("exception ADD peer=%{public}@ name=%{public}@ username=%{public}@", peerId,
                 name ?: @"(none)", username ?: @"(none)");
        TGExtraShowToast([TGExtraLocalization localizedStringForKey:@"GHOST_EXCEPTION_ADDED_TOAST"]);
    }

    updateGhostExceptionButtonAppearance(sender, !wasException);

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
}

@end

void TGExtraUpdateGhostExceptionButton(ASDisplayNode *headerNode, long long peerId) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TGExtraUpdateGhostExceptionButton(headerNode, peerId);
        });
        return;
    }

    @try {
        UIView *headerView = headerNode.view;
        if (!headerView) return;

        UIButton *existing = (UIButton *)[headerView viewWithTag:kTGExtraGhostExceptionButtonTag];

        BOOL isOwnProfile = NO;
        BOOL ownIdKnown = NO;
        if (peerId > 0) {
            NSNumber *currentUserId = [TGExtraProfileBridge getOwnUserIdFromNode:headerNode];
            ownIdKnown = (currentUserId != nil);
            isOwnProfile = (ownIdKnown && currentUserId.longLongValue == peerId);
            tgextraDiag("ghost-button peer=%lld me=%lld own=%d",
                     peerId, ownIdKnown ? currentUserId.longLongValue : -1, isOwnProfile);
        }
        if (peerId <= 0 || isOwnProfile || !ownIdKnown) {
            if (existing) [existing removeFromSuperview];
            return;
        }

        BOOL isException = [TGExtraGhostExceptions containsPeerId:peerId];

        UIButton *button = existing;
        if (!button) {
            button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = kTGExtraGhostExceptionButtonTag;
            button.layer.zPosition = 9999;
            button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                      UIViewAutoresizingFlexibleBottomMargin;
            [button addTarget:[TGExtraGhostExceptionButtonTarget shared]
                       action:@selector(handleTap:)
             forControlEvents:UIControlEventTouchUpInside];
            [headerView addSubview:button];
        }

        objc_setAssociatedObject(button, kTGExtraGhostPeerIdKey, @(peerId),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        TGExtraWeakBox *box = [TGExtraWeakBox new];
        box.object = headerNode;
        objc_setAssociatedObject(button, kTGExtraGhostNodeBoxKey, box,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        const CGFloat buttonSize = 44.0;
        const CGFloat rightMargin = 12.0;
        const CGFloat belowNavBar = 52.0;

        UIWindow *window = headerView.window ?: UIApplication.sharedApplication.keyWindow;
        CGRect frame;
        if (window) {
            CGPoint desired = CGPointMake(
                CGRectGetWidth(window.bounds) - buttonSize - rightMargin,
                window.safeAreaInsets.top + belowNavBar);
            CGPoint local = [headerView convertPoint:desired fromView:nil];
            frame = CGRectMake(local.x, local.y, buttonSize, buttonSize);
        } else {
            frame = CGRectMake(CGRectGetWidth(headerView.bounds) - buttonSize - rightMargin,
                               100.0, buttonSize, buttonSize);
        }
        button.frame = frame;
        updateGhostExceptionButtonAppearance(button, isException);
        [headerView bringSubviewToFront:button];
    } @catch (NSException *e) {}
}
