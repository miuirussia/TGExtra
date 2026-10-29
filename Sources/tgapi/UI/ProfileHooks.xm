#import "HostDisplayNode.h"
#import "ProfileBridge.h"
#import "../Logger/Logger.h"
#import <objc/message.h>
static BOOL injectBadgeToNode(ASDisplayNode *textNode, ASDisplayNode *headerNode, long long peerId) {
    @try {
        if (!textNode.view || !headerNode.view) return NO;

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
            UIView *oldBadge = [headerNode.view viewWithTag:9988];
            if (oldBadge) [oldBadge removeFromSuperview];
            return NO;
        }

        UILabel *badge = (UILabel *)[headerNode.view viewWithTag:9988];
        if (!badge) {
            badge = [[UILabel alloc] init];
            badge.tag = 9988;
            badge.font = [UIFont boldSystemFontOfSize:10];
            badge.textColor = [UIColor whiteColor];
            badge.layer.cornerRadius = 4;
            badge.layer.masksToBounds = YES;
            badge.layer.zPosition = 9999;
            [headerNode.view addSubview:badge];
        }

        badge.backgroundColor = badgeColor;
        badge.text = [NSString stringWithFormat:@" %@ ", prefix];
        [badge sizeToFit];

        CGRect textFrame = [textNode.view convertRect:textNode.view.bounds toView:headerNode.view];
        if (textFrame.size.width > 0) {
            badge.frame = CGRectMake(textFrame.origin.x + textFrame.size.width + 6,
                                     textFrame.origin.y + (textFrame.size.height - badge.frame.size.height) / 2.0,
                                     badge.frame.size.width, badge.frame.size.height);
        } else {
            badge.frame = CGRectMake(headerNode.view.frame.size.width - badge.frame.size.width - 15, 45, badge.frame.size.width, badge.frame.size.height);
        }
        if (!CGRectContainsRect(headerNode.view.bounds, CGRectInset(badge.frame, -1, -1))) {
            badge.hidden = YES;
            return NO;
        }

        badge.hidden = NO;
        [headerNode.view bringSubviewToFront:badge];
        return YES;
    } @catch (NSException *e) {}
    return NO;
}

static BOOL recursiveSearchAndInject(ASDisplayNode *node, ASDisplayNode *header, long long peerId) {
    if (!node) return NO;
    NSString *cls = NSStringFromClass([node class]);

    if ([cls containsString:@"TextNode"] && ![cls containsString:@"Accessibility"] && ![cls containsString:@"Button"]) {
        if (injectBadgeToNode(node, header, peerId)) return YES;
    }
    @try {
        NSArray *subs = node.subnodes;
        for (ASDisplayNode *sub in subs) {
            if (recursiveSearchAndInject(sub, header, peerId)) return YES;
        }
    } @catch (NSException *e) {}
    return NO;
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

%hook ASDisplayNode
- (void)layout {
    %orig;

    NSString *cls = NSStringFromClass([self class]);

    BOOL isProfileHeader = [cls containsString:@"PeerInfoHeaderNode"];

    if (isProfileHeader) {
        long long peerId = 0;
        peerId = [[TGExtraProfileBridge getPeerIdFromNode:self] longLongValue];

        SEL peerSel = NSSelectorFromString(@"peer");
        BOOL headerHasNoPeer = NO;
        if ([self respondsToSelector:peerSel]) {
            id (*getPeer)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            headerHasNoPeer = (getPeer(self, peerSel) == nil);
        }
        if (peerId == 0 && headerHasNoPeer) {
            peerId = [[TGExtraProfileBridge getOwnUserIdFromNode:self] longLongValue];
        }
        recursiveSearchAndInject(self, self, peerId);

        tgextraDiagProfileNode(cls, peerId, self);

        TGExtraUpdateGhostExceptionButton(self, peerId);
    }

}
%end

%ctor { dispatch_async(dispatch_get_main_queue(), ^{ %init; }); }
