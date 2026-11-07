#import "HostDisplayNode.h"
#import "ProfileBridge.h"
#import "TGExtraLocalization.h"
#import "../Logger/Logger.h"
#import <objc/runtime.h>
#include <math.h>

@interface NSObject (TGExtraProfilePeer)
- (id)peer;
@end

static char profileTitleTransformKey;

static void restoreProfileTitleAlignment(ASDisplayNode *title) {
    NSValue *original = objc_getAssociatedObject(title.view, &profileTitleTransformKey);
    if (!original) return;
    [UIView performWithoutAnimation:^{
        title.view.layer.sublayerTransform = original.CATransform3DValue;
    }];
    objc_setAssociatedObject(title.view, &profileTitleTransformKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static CGFloat visibleProfileViewAlpha(UIView *view, UIView *headerView) {
    CGFloat alpha = 1.0;
    for (UIView *current = view; current; current = current.superview) {
        if (current.hidden) return 0.0;
        if (current == headerView) return alpha;
        alpha *= current.alpha;
    }
    return 0.0;
}

static ASDisplayNode *visibleProfileTitleNode(ASDisplayNode *node, UIView *headerView) {
    if (!node || visibleProfileViewAlpha(node.view, headerView) < 0.01) return nil;
    ASDisplayNode *result = nil;
    NSString *name = NSStringFromClass([node class]);
    if ([name containsString:@"TextNode"] && ![name containsString:@"MultiScale"] &&
        !CGRectIsEmpty(node.view.bounds)) {
        result = node;
    }
    for (ASDisplayNode *child in node.subnodes) {
        ASDisplayNode *candidate = visibleProfileTitleNode(child, headerView);
        if (candidate && (!result || visibleProfileViewAlpha(candidate.view, headerView) >
                                    visibleProfileViewAlpha(result.view, headerView))) {
            result = candidate;
        }
    }
    return result;
}

static BOOL profileBadgeIntersectsControl(UIView *view, UIView *headerView, CGRect frame) {
    if (view.hidden || view.alpha < 0.01) return NO;
    ASDisplayNode *node = [view respondsToSelector:@selector(asyncdisplaykit_node)] ? [view asyncdisplaykit_node] : nil;
    if ([view isKindOfClass:[UIControl class]] || [NSStringFromClass([node class]) containsString:@"Button"]) {
        CGRect controlFrame = [view convertRect:view.bounds toView:headerView];
        if (CGRectIntersectsRect(frame, CGRectInset(controlFrame, -6, -6))) return YES;
    }
    for (UIView *child in view.subviews) {
        if (profileBadgeIntersectsControl(child, headerView, frame)) return YES;
    }
    return NO;
}

static void updateProfileBadge(ASDisplayNode *headerNode, long long peerId) {
    @try {
        UIView *headerView = headerNode.view;
        if (!headerView) return;

        NSString *prefix = nil;
        UIColor *badgeColor = [UIColor colorWithRed:0.0 green:0.5 blue:1.0 alpha:1.0]; // TGExtra Blue

        if (peerId == 5576711589 || peerId == 7846965839) {
            prefix = @"👑 TGExtra Owner";
            badgeColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.0 alpha:1.0]; // Gold
        } else {
            NSNumber *currId = [TGExtraProfileBridge getOwnUserIdFromNode:headerNode];
            if (currId && [currId longLongValue] == peerId) {
                prefix = @"✨ TGExtra User";
            }
        }

        if (!prefix) {
            UIView *oldBadge = [headerView viewWithTag:9988];
            if (oldBadge) [oldBadge removeFromSuperview];
            return;
        }

        UILabel *badge = (UILabel *)[headerView viewWithTag:9988];
        badge.hidden = YES;
        ASDisplayNode *title = [TGExtraProfileBridge getTitleNodeFromNode:headerNode];
        ASDisplayNode *textNode = visibleProfileTitleNode(title, headerView);
        if (!textNode) return;

        if (!badge) {
            badge = [[UILabel alloc] init];
            badge.tag = 9988;
            badge.font = [UIFont boldSystemFontOfSize:10];
            badge.textColor = [UIColor whiteColor];
            badge.layer.cornerRadius = 4;
            badge.layer.masksToBounds = YES;
        }
        // Inherit the title's movement, scale and fades during native header animations.
        if (badge.superview != textNode.view) [textNode.view addSubview:badge];

        badge.backgroundColor = badgeColor;
        badge.text = [NSString stringWithFormat:@" %@ ", prefix];
        [badge sizeToFit];

        CGRect textFrame = [textNode.view convertRect:textNode.view.bounds toView:headerView];
        // Telegram puts premium, verification and emoji status views outside the text bounds.
        for (UIView *icon in textNode.view.subviews) {
            if (icon != badge && icon.tag != 9989 && !icon.hidden && icon.alpha >= 0.01 && !CGRectIsEmpty(icon.bounds)) {
                textFrame = CGRectUnion(textFrame, [icon convertRect:icon.bounds toView:headerView]);
            }
        }
        CGRect availableBounds = UIEdgeInsetsInsetRect(headerView.bounds, headerView.safeAreaInsets);
        availableBounds = CGRectInset(availableBounds, 8, 1);
        CGSize size = [textNode.view convertRect:badge.bounds toView:headerView].size;
        CGFloat y = CGRectGetMidY(textFrame) - size.height / 2.0;
        CGRect candidates[] = {
            CGRectMake(CGRectGetMaxX(textFrame) + 6, y, size.width, size.height),
            CGRectMake(CGRectGetMinX(textFrame) - 6 - size.width, y, size.width, size.height)
        };
        for (NSUInteger i = 0; i < 2; i++) {
            CGRect frame = candidates[i];
            if (!CGRectContainsRect(availableBounds, frame) || profileBadgeIntersectsControl(headerView, headerView, frame)) continue;
            badge.frame = [headerView convertRect:frame toView:textNode.view];
            badge.hidden = NO;
            [textNode.view bringSubviewToFront:badge];
            return;
        }
        badge.hidden = YES;
    } @catch (NSException *e) {}
}

static void updateMutualContactIcon(ASDisplayNode *headerNode) {
    UIView *headerView = headerNode.view;
    UIImageView *icon = (UIImageView *)[headerView viewWithTag:9989];
    icon.hidden = YES;
    if (![TGExtraProfileBridge isMutualContactFromNode:headerNode]) {
        [icon removeFromSuperview];
        return;
    }
    ASDisplayNode *titleRoot = [TGExtraProfileBridge getTitleNodeFromNode:headerNode];
    ASDisplayNode *title = visibleProfileTitleNode(titleRoot, headerView);
    if (!title) return;
    if (!icon) {
        icon = [UIImageView new];
        icon.hidden = YES;
        icon.tag = 9989;
        icon.tintColor = UIColor.systemBlueColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.isAccessibilityElement = YES;
        icon.accessibilityLabel = [TGExtraLocalization localizedStringForKey:@"PROFILE_MUTUAL_CONTACT"];
    }
    NSAttributedString *text = [TGExtraProfileBridge getStoredField:@"attributedText" fromNode:title];
    UIFont *font = text.length ? [text attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] : nil;
    if (!font) font = [UIFont systemFontOfSize:title.view.bounds.size.height * 0.85 weight:UIFontWeightMedium];
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithFont:font scale:UIImageSymbolScaleSmall];
    icon.image = [UIImage systemImageNamed:@"person.2.fill" withConfiguration:configuration];
    CGRect occupied = [title.view convertRect:title.view.bounds toView:headerView];
    for (UIView *child in title.view.subviews) {
        if (child != icon && !child.hidden && child.alpha >= 0.01 && !CGRectIsEmpty(child.bounds)) {
            occupied = CGRectUnion(occupied, [child convertRect:child.bounds toView:headerView]);
        }
    }
    CGRect available = CGRectInset(UIEdgeInsetsInsetRect(headerView.bounds, headerView.safeAreaInsets), 8, 1);
    CGFloat scale = UIScreen.mainScreen.scale;
    CGFloat baseline = CGRectGetMinY(title.view.bounds) + floor(font.ascender * scale) / scale;
    CGFloat localY = baseline - (icon.image.size.height - icon.image.baselineOffsetFromBottom);
    CGRect imageFrame = [title.view convertRect:(CGRect){CGPointMake(0, localY), icon.image.size} toView:headerView];
    CGSize size = imageFrame.size;
    CGFloat y = imageFrame.origin.y;
    CGRect candidates[] = {
        CGRectMake(CGRectGetMaxX(occupied) + 6, y, size.width, size.height),
        CGRectMake(CGRectGetMinX(occupied) - 6 - size.width, y, size.width, size.height)
    };
    for (NSUInteger i = 0; i < 2; i++) {
        // Match Telegram's centering of a name together with its native status icons.
        CGFloat offset = fabs(CGRectGetMidX(occupied) - CGRectGetMidX(available)) <= 1.0
            ? (i == 0 ? -(size.width + 6) / 2 : (size.width + 6) / 2) : 0;
        CGRect group = CGRectOffset(CGRectUnion(occupied, candidates[i]), offset, 0);
        CGRect displayedIcon = CGRectOffset(candidates[i], offset, 0);
        if (!CGRectContainsRect(available, group) || profileBadgeIntersectsControl(headerView, headerView, displayedIcon)) continue;
        CGRect frame = [headerView convertRect:candidates[i] toView:title.view];
        [UIView performWithoutAnimation:^{
            icon.frame = frame;
            if (icon.superview != title.view) [title.view addSubview:icon];
            if (offset != 0) {
                CALayer *layer = titleRoot.view.layer;
                CATransform3D original = layer.sublayerTransform;
                objc_setAssociatedObject(titleRoot.view, &profileTitleTransformKey,
                    [NSValue valueWithCATransform3D:original], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                CGFloat localOffset = [titleRoot.view convertPoint:CGPointMake(offset, 0) fromView:headerView].x -
                    [titleRoot.view convertPoint:CGPointZero fromView:headerView].x;
                layer.sublayerTransform = CATransform3DTranslate(original, localOffset, 0, 0);
            }
            icon.hidden = NO;
        }];
        break;
    }
}

static void tgextraDiagProfileNode(NSString *cls, long long peerId, ASDisplayNode *node) {
#if TGEXTRA_DIAG
    static NSMutableSet *seen = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ seen = [NSMutableSet new]; });

    NSString *key = [NSString stringWithFormat:@"%@|%lld", cls, peerId];
    BOOL isNew = NO;
    @synchronized(seen) {
        if (![seen containsObject:key]) {
            [seen addObject:key];
            isNew = YES;
        }
    }
    if (!isNew) return;

    tgextraDiag("profile-node cls=%{public}@ peerId=%lld", cls, peerId);

    static BOOL dumped = NO;
    if (!dumped && peerId == 0 && [cls containsString:@"Header"]) {
        dumped = YES;
        @try {
            tgextraDiag("header-dump %{public}@", [TGExtraProfileBridge debugPeerCandidates:node]);
        } @catch (NSException *e) {
            tgextraDiag("header-dump failed: %{public}@", e);
        }
    }
#endif
}

%group TGExtraProfileViewLayout
%hook _ASDisplayView
- (void)layoutSubviews {
    %orig;

    ASDisplayNode *node = [(UIView *)self asyncdisplaykit_node];
    NSString *cls = NSStringFromClass([node class]);

    BOOL isProfileHeader = [cls containsString:@"PeerInfoHeaderNode"];

    if (isProfileHeader) {
        restoreProfileTitleAlignment([TGExtraProfileBridge getTitleNodeFromNode:node]);
        long long peerId = 0;
        peerId = [[TGExtraProfileBridge getPeerIdFromNode:node] longLongValue];

        BOOL headerHasNoPeer = NO;
        if ([node respondsToSelector:@selector(peer)]) {
            headerHasNoPeer = ([node peer] == nil);
        }
        if (peerId == 0 && headerHasNoPeer) {
            peerId = [[TGExtraProfileBridge getOwnUserIdFromNode:node] longLongValue];
        }
        updateProfileBadge(node, peerId);
        updateMutualContactIcon(node);

        tgextraDiagProfileNode(cls, peerId, node);

        TGExtraUpdateGhostExceptionButton(node, peerId);
    }

}
%end
%end

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class view = NSClassFromString(@"_ASDisplayView");
        if ([view instancesRespondToSelector:@selector(asyncdisplaykit_node)] &&
            [view instancesRespondToSelector:@selector(layoutSubviews)]) {
            %init(TGExtraProfileViewLayout, _ASDisplayView = view);
        }
    });
}
