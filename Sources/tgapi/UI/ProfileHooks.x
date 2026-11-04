#import "HostDisplayNode.h"
#import "ProfileBridge.h"
#import "../Logger/Logger.h"

@interface NSObject (TGExtraProfilePeer)
- (id)peer;
@end

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
            if (icon != badge && !icon.hidden && icon.alpha >= 0.01 && !CGRectIsEmpty(icon.bounds)) {
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
