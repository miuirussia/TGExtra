#import "Headers.h"
#import "MessageBadges.h"
#import "../Headers.h"
#import "../Logger/Logger.h"
#import "EditHistoryViewController.h"
#import "EditHistoryAppearance.h"
#import <math.h>
#define TGExtraLoc(key) [TGExtraLocalization localizedStringForKey:(key)]

static const NSInteger kTGExtraEditBadgeTag = 8899;
static char kTGExtraEditMsgIdKey;
static char kTGExtraEditPeerKey;
static char kTGExtraEditAccountKey;
static char kTGExtraEditNamespaceKey;

void TGExtraClearEditBadgeBinding(UIButton *badge) {
    if (!badge) return;
    badge.hidden = YES;
    objc_setAssociatedObject(badge, &kTGExtraEditMsgIdKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditPeerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditAccountKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditNamespaceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@interface TGExtraEditHistoryButtonTarget : NSObject
+ (instancetype)shared;
@end

@implementation TGExtraEditHistoryButtonTarget

+ (instancetype)shared {
    static TGExtraEditHistoryButtonTarget *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (void)handleTap:(UIButton *)sender {
    NSNumber *msgId = objc_getAssociatedObject(sender, &kTGExtraEditMsgIdKey);
    if (!msgId) return;
    NSNumber *peerKey = objc_getAssociatedObject(sender, &kTGExtraEditPeerKey);
    NSString *account = objc_getAssociatedObject(sender, &kTGExtraEditAccountKey);
    NSNumber *messageNamespace = objc_getAssociatedObject(sender, &kTGExtraEditNamespaceKey);

    ASDisplayNode *node = TGExtraMessageNodeForView(sender.superview);
    NSDictionary *current = node ? [TLParser messageStateFromNode:node observe:NO] : nil;
    if (![msgId isEqual:current[@"id"]] || ![peerKey isEqual:current[@"peer"]] ||
        ![account isEqual:current[@"account"]] || ![messageNamespace isEqual:current[@"namespace"]]) {
        TGExtraClearEditBadgeBinding(sender);
        if (node) TGExtraScheduleMessageBadgeUpdate(node);
        return;
    }

    NSArray<NSString *> *versions = [TLParser editHistoryForId:msgId peer:peerKey account:account messageNamespace:messageNamespace];
    if (versions.count < 2) return;
    NSArray<NSDictionary *> *details = [TLParser editRevisionDetailsForId:msgId peer:peerKey account:account messageNamespace:messageNamespace];

    TGExtraEditHistoryViewController *history = [[TGExtraEditHistoryViewController alloc] initWithVersions:versions details:details];
    UINavigationController *sheet = [[UINavigationController alloc] initWithRootViewController:history];

    UIViewController *top = sender.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if (top) [top presentViewController:sheet animated:YES completion:nil];
}

@end

static void tgextraCollectEditBadgeObstacles(UIView *view, UIView *root, UIButton *badge, NSMutableArray<NSValue *> *frames) {
    if (view == badge || view.hidden || view.alpha <= 0.01) return;
    if (view != root) {
        ASDisplayNode *node = [view respondsToSelector:@selector(asyncdisplaykit_node)] ? [view asyncdisplaykit_node] : nil;
        NSString *name = NSStringFromClass([node class]);
        BOOL isControl = [view isKindOfClass:[UIControl class]] || [name containsString:@"Button"] ||
            [name containsString:@"ThreadInfo"] || [name containsString:@"ReplyInfo"];
        if (isControl || view.tag == 8898) {
            CGRect frame = [root convertRect:view.bounds fromView:view];
            if (!CGRectIsEmpty(frame)) [frames addObject:[NSValue valueWithCGRect:frame]];
            return;
        }
    }
    for (UIView *child in view.subviews) tgextraCollectEditBadgeObstacles(child, root, badge, frames);
}

static CGRect tgextraEditBadgeFrame(CGRect bounds, CGRect statusFrame, BOOL hasStatus, NSArray<NSValue *> *obstacles) {
    CGFloat side = MIN(44.0, MIN(CGRectGetWidth(bounds), CGRectGetHeight(bounds)));
    CGFloat x = hasStatus ? CGRectGetMaxX(statusFrame) + 8.0 : CGRectGetMaxX(bounds) - side;
    CGFloat y = hasStatus ? CGRectGetMidY(statusFrame) - side / 2.0 : CGRectGetMaxY(bounds) - side;
    x = MAX(CGRectGetMinX(bounds), MIN(x, CGRectGetMaxX(bounds) - side));
    y = MAX(CGRectGetMinY(bounds), MIN(y, CGRectGetMaxY(bounds) - side));

    const CGFloat gap = 8.0;
    NSMutableArray<NSNumber *> *xs = [NSMutableArray arrayWithArray:@[@(x), @(CGRectGetMinX(bounds)), @(CGRectGetMaxX(bounds) - side)]];
    NSMutableArray<NSNumber *> *ys = [NSMutableArray arrayWithArray:@[@(y), @(CGRectGetMinY(bounds)), @(CGRectGetMaxY(bounds) - side)]];
    for (NSValue *value in obstacles) {
        CGRect frame = value.CGRectValue;
        [xs addObject:@(CGRectGetMinX(frame) - gap - side)];
        [xs addObject:@(CGRectGetMaxX(frame) + gap)];
        [ys addObject:@(CGRectGetMinY(frame) - gap - side)];
        [ys addObject:@(CGRectGetMaxY(frame) + gap)];
    }
    CGRect best = CGRectNull;
    CGFloat bestDistance = CGFLOAT_MAX;
    for (NSNumber *candidateX in xs) {
        for (NSNumber *candidateY in ys) {
            CGRect candidate = CGRectMake(candidateX.doubleValue, candidateY.doubleValue, side, side);
            if (!CGRectContainsRect(bounds, candidate)) continue;
            BOOL occupied = NO;
            for (NSValue *value in obstacles) {
                if (CGRectIntersectsRect(candidate, CGRectInset(value.CGRectValue, -gap, -gap))) {
                    occupied = YES;
                    break;
                }
            }
            if (occupied) continue;
            CGFloat distance = fabs(candidate.origin.x - x) * (CGRectGetHeight(bounds) + 1.0) + fabs(candidate.origin.y - y);
            if (distance < bestDistance) {
                best = candidate;
                bestDistance = distance;
            }
        }
    }
    return best;
}

void TGExtraUpdateEditBadge(ASDisplayNode *node, NSNumber *msgId, NSNumber *peerKey, NSString *account, NSNumber *messageNamespace) {
    UIButton *badge = nil;
    for (UIView *v in node.view.subviews) {
        if (v.tag == kTGExtraEditBadgeTag) { badge = (UIButton *)v; break; }
    }

    NSUInteger versions = (msgId != nil && messageNamespace != nil)
        ? [TLParser editHistoryForId:msgId peer:peerKey account:account messageNamespace:messageNamespace].count
        : 0;
    BOOL hasHistory = (versions > 1);

#if TGEXTRA_DIAG
    {
        static NSMutableSet *seen = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ seen = [NSMutableSet set]; });
        NSString *key = [NSString stringWithFormat:@"%@/%@/%@/%lu", account, msgId, peerKey,
                         (unsigned long)versions];
        BOOL report = NO;
        @synchronized(seen) {
            if (seen.count < 40 && ![seen containsObject:key]) {
                [seen addObject:key];
                report = YES;
            }
        }
        if (report) {
            tgextraDiag("edit-badge account=%{public}s id=%{public}s peer=%{public}s versions=%lu drawn=%d",
                   account ? account.UTF8String : "nil",
                   msgId ? msgId.stringValue.UTF8String : "nil",
                   peerKey ? peerKey.stringValue.UTF8String : "nil",
                   (unsigned long)versions, hasHistory);
        }
    }
#endif

    if (!hasHistory || CGRectIsEmpty(node.view.bounds)) {
        TGExtraClearEditBadgeBinding(badge);
        return;
    }

    if (!badge) {
        badge = [UIButton buttonWithType:UIButtonTypeSystem];
        badge.tag = kTGExtraEditBadgeTag;
        UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular];
        [badge setImage:[UIImage systemImageNamed:@"pencil" withConfiguration:symbol]
               forState:UIControlStateNormal];
        UIView *background = [[UIView alloc] init];
        background.tag = 8897;
        background.userInteractionEnabled = NO;
        background.isAccessibilityElement = NO;
        [badge insertSubview:background atIndex:0];
        [badge addTarget:[TGExtraEditHistoryButtonTarget shared]
                  action:@selector(handleTap:)
        forControlEvents:UIControlEventTouchUpInside];
        [node.view addSubview:badge];
    }
    objc_setAssociatedObject(badge, &kTGExtraEditMsgIdKey, msgId, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditPeerKey, peerKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditAccountKey, account, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(badge, &kTGExtraEditNamespaceKey, messageNamespace, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    node.view.userInteractionEnabled = YES;

    ASDisplayNode *statusNode = TGExtraFindDisplayNode(node, @"ChatMessageDateAndStatusNode");
    BOOL hasStatus = statusNode && statusNode.view;
    CGRect statusFrame = hasStatus ? [node.view convertRect:statusNode.view.bounds fromView:statusNode.view] : CGRectZero;
    NSMutableArray<NSValue *> *obstacles = [NSMutableArray array];
    tgextraCollectEditBadgeObstacles(node.view, node.view, badge, obstacles);
    if (hasStatus) [obstacles addObject:[NSValue valueWithCGRect:statusFrame]];
    CGRect frame = tgextraEditBadgeFrame(node.view.bounds, statusFrame, hasStatus, obstacles);
    if (CGRectIsNull(frame)) {
        TGExtraClearEditBadgeBinding(badge);
        return;
    }
    badge.frame = frame;
    badge.autoresizingMask = UIViewAutoresizingNone;
    CGFloat inset = MAX(0.0, (CGRectGetWidth(badge.frame) - 18.0) / 2.0);
    badge.contentEdgeInsets = UIEdgeInsetsMake(inset, inset, inset, inset);

    NSDictionary *colors = [TGExtraEditHistoryAppearance buttonColorsFromNode:node];
    UIColor *fill = [colors[@"fill"] isKindOfClass:UIColor.class] ? colors[@"fill"] : [UIColor colorWithWhite:0.0 alpha:0.3];
    UIColor *foreground = [colors[@"foreground"] isKindOfClass:UIColor.class] ? colors[@"foreground"] : UIColor.whiteColor;
    UIColor *stroke = [colors[@"stroke"] isKindOfClass:UIColor.class] ? colors[@"stroke"] : UIColor.clearColor;
    UIView *background = [badge viewWithTag:8897];
    CGFloat diameter = MIN(30.0, CGRectGetWidth(badge.bounds));
    background.frame = CGRectMake((CGRectGetWidth(badge.bounds) - diameter) / 2.0,
                                  (CGRectGetHeight(badge.bounds) - diameter) / 2.0, diameter, diameter);
    background.layer.cornerRadius = diameter / 2.0;
    background.backgroundColor = fill;
    background.layer.borderColor = stroke.CGColor;
    background.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
    badge.tintColor = foreground;

    badge.accessibilityLabel = TGExtraLoc(@"EDIT_HISTORY_TITLE");
    badge.hidden = NO;
    [node.view bringSubviewToFront:badge];
}
