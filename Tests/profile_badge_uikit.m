#import "HostDisplayNode.h"
#import "ProfileBridge.h"
#import "TGExtraLocalization.h"
#include <math.h>

@interface _ASDisplayView : UIView
@property (nonatomic, weak) ASDisplayNode *node;
@property NSUInteger layouts;
@end
@implementation _ASDisplayView
- (ASDisplayNode *)asyncdisplaykit_node { return self.node; }
- (void)layoutSubviews { [super layoutSubviews]; self.layouts++; }
@end

@interface ASDisplayNode ()
@property (atomic, readwrite) UIView *view;
@property (atomic, copy, readwrite) NSArray *subnodes;
@end
@implementation ASDisplayNode
@dynamic layer, accessibilityLabel, hidden, alpha, backgroundColor, frame, position;
- (instancetype)init {
    if ((self = [super init])) {
        _ASDisplayView *view = [_ASDisplayView new];
        view.node = self;
        self.view = view;
        self.subnodes = @[];
    }
    return self;
}
- (ASDisplayNode *)supernode { return nil; }
- (void)setNeedsLayout { [self.view setNeedsLayout]; }
- (void)layoutIfNeeded { [self.view layoutIfNeeded]; }
@end
@interface ImmediateTextNode : ASDisplayNode
@property NSAttributedString *attributedText;
@end
@implementation ImmediateTextNode @end
@interface MultiScaleTextNode : ASDisplayNode @end
@implementation MultiScaleTextNode @end
@interface PeerInfoHeaderNavigationButton : ASDisplayNode @end
@implementation PeerInfoHeaderNavigationButton @end
@interface PeerInfoHeaderNode : ASDisplayNode
@property ASDisplayNode *titleNode;
@property NSNumber *peer;
@property BOOL mutual;
@end
@implementation PeerInfoHeaderNode @end

static NSUInteger ghostUpdates;
void TGExtraUpdateGhostExceptionButton(ASDisplayNode *node, long long peerId) { ghostUpdates++; }
@implementation TGExtraProfileBridge
+ (id)sharedContext { return nil; }
+ (void)setSharedContext:(id)context {}
+ (NSNumber *)getPeerIdFromNode:(PeerInfoHeaderNode *)node { return node.peer; }
+ (id)getTitleNodeFromNode:(PeerInfoHeaderNode *)node { return node.titleNode; }
+ (BOOL)isMutualContactFromNode:(PeerInfoHeaderNode *)node { return node.mutual; }
+ (BOOL)shouldShowProfileInfoFromNode:(id)node { return YES; }
+ (NSNumber *)getPaneOriginFromNode:(id)node contentHeight:(double)height { return nil; }
+ (id)getInfoSectionFromNode:(id)node { return nil; }
+ (id)getStoredField:(NSString *)field fromNode:(id)node {
    return [field isEqualToString:@"attributedText"] && [node isKindOfClass:ImmediateTextNode.class] ? [node attributedText] : nil;
}
+ (NSNumber *)getOwnUserIdFromNode:(id)node { return @42; }
+ (NSNumber *)getCurrentUserId { return @42; }
+ (NSDictionary *)getPeerDisplayInfoFromNode:(id)node { return @{}; }
+ (NSString *)debugPeerCandidates:(id)node { return @""; }
@end

@implementation TGExtraLocalization
@dynamic localization, languageCode;
+ (instancetype)shared { return nil; }
+ (NSString *)localizedStringForKey:(NSString *)key { return key; }
@end

static void addNode(ASDisplayNode *parent, ASDisplayNode *child, CGRect frame) {
    child.view.frame = frame;
    parent.subnodes = [parent.subnodes arrayByAddingObject:child];
    [parent.view addSubview:child.view];
}

static CGRect badgeFrame(UILabel *badge, PeerInfoHeaderNode *header) {
    return [badge convertRect:badge.bounds toView:header.view];
}

int main(void) {
    @autoreleasepool {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        PeerInfoHeaderNode *header = [PeerInfoHeaderNode new];
        header.peer = @42;
        header.view.frame = CGRectMake(0, 0, 393, 400);
        PeerInfoHeaderNavigationButton *navigation = [PeerInfoHeaderNavigationButton new];
        addNode(header, navigation, CGRectMake(310, 45, 70, 40));
        addNode(navigation, [ImmediateTextNode new], CGRectMake(0, 0, 60, 30));
        [header.view layoutSubviews];
        NSCAssert(![header.view viewWithTag:9988], @"Never anchor a badge to navigation text when the title is absent");

        header.titleNode = [MultiScaleTextNode new];
        addNode(header, header.titleNode, CGRectMake(150, 180, 0, 0));
        ASDisplayNode *regular = [ASDisplayNode new];
        ASDisplayNode *expanded = [ASDisplayNode new];
        addNode(header.titleNode, expanded, CGRectZero);
        addNode(header.titleNode, regular, CGRectZero);
        expanded.view.alpha = 0;
        ImmediateTextNode *text = [ImmediateTextNode new];
        ImmediateTextNode *expandedText = [ImmediateTextNode new];
        addNode(regular, text, CGRectMake(0, 0, 80, 28));
        addNode(expanded, expandedText, CGRectMake(-50, 50, 60, 24));
        UIView *status = [[UIView alloc] initWithFrame:CGRectMake(84, 0, 24, 28)];
        [text.view addSubview:status];
        [header.view layoutSubviews];
        UILabel *badge = (UILabel *)[header.view viewWithTag:9988];
        NSCAssert(badge && !badge.hidden && CGRectGetMinX(badgeFrame(badge, header)) == 264,
                  @"Use visible title geometry and clear emoji status, even with zero-sized title containers");
        NSCAssert(CGRectGetMidY(badgeFrame(badge, header)) == 194, @"Align with the name instead of navigation buttons");
        NSCAssert(ghostUpdates > 0 && ((_ASDisplayView *)header.view).layouts > 0,
                  @"Preserve native layout and ghost button refresh");

        header.view.frame = CGRectMake(0, 0, 280, 400);
        [header.view layoutSubviews];
        NSCAssert(!badge.hidden && CGRectGetMaxX(badgeFrame(badge, header)) == 144, @"Move left when the viewport narrows");
        UIButton *control = [[UIButton alloc] initWithFrame:badgeFrame(badge, header)];
        [header.view addSubview:control];
        [header.view layoutSubviews];
        NSCAssert(badge.hidden, @"Hide when both sides are occupied");
        control.hidden = YES;
        [header.view layoutSubviews];
        NSCAssert(!badge.hidden, @"Restore when space becomes available");

        header.view.frame = CGRectMake(0, 0, 393, 400);
        navigation.view.frame = CGRectMake(260, 175, 120, 40);
        [header.view layoutSubviews];
        NSCAssert(!badge.hidden && CGRectGetMaxX(badgeFrame(badge, header)) == 144,
                  @"Also avoid native ASDisplayNode buttons that are not UIControls");
        navigation.view.hidden = YES;
        header.titleNode.view.transform = CGAffineTransformMakeScale(0.75, 0.75);
        [header.view layoutSubviews];
        CGRect iconFrame = [status convertRect:status.bounds toView:header.view];
        NSCAssert(!badge.hidden && fabs(CGRectGetMinX(badgeFrame(badge, header)) - CGRectGetMaxX(iconFrame) - 6) < 0.001,
                  @"Recompute after scaling and scrolling");
        CGRect beforeScroll = badgeFrame(badge, header);
        header.titleNode.view.center = CGPointMake(150, 140);
        NSCAssert(fabs(CGRectGetMinY(badgeFrame(badge, header)) - CGRectGetMinY(beforeScroll) + 40) < 0.001,
                  @"Follow native title movement even without another header layout pass");

        regular.view.alpha = 0.2;
        expanded.view.alpha = 0.8;
        [header.view layoutSubviews];
        CGRect expandedFrame = [expandedText.view convertRect:expandedText.view.bounds toView:header.view];
        NSCAssert(!badge.hidden && badge.superview == expandedText.view && badge.alpha == 1 &&
                  fabs(CGRectGetMidY(badgeFrame(badge, header)) - CGRectGetMidY(expandedFrame)) < 0.001,
                  @"Follow the dominant expanded title state");
        header.titleNode.view.hidden = YES;
        [header.view layoutSubviews];
        NSCAssert(badge.hidden, @"Hide stale badges when the title disappears");
        header.titleNode.view.hidden = NO;
        regular.view.alpha = 1;
        expanded.view.alpha = 0;
        header.titleNode.view.transform = CGAffineTransformIdentity;
        text.view.frame = CGRectMake(-140, 0, 370, 28);
        [header.view layoutSubviews];
        NSCAssert(badge.hidden, @"A long name must not push the badge outside the screen");
        text.view.frame = CGRectMake(0, 0, 80, 28);
        header.peer = @5576711589;
        [header.view layoutSubviews];
        NSCAssert(!badge.hidden && [badge.text containsString:@"Owner"], @"Keep the owner badge");
        header.peer = @43;
        [header.view layoutSubviews];
        NSCAssert(![header.view viewWithTag:9988], @"Remove the badge when the header is reused for another peer");
        header.mutual = YES;
        text.view.frame = CGRectMake(-140, 0, 370, 28);
        [header.view layoutSubviews];
        UIView *unplacedIcon = [header.view viewWithTag:9989];
        NSCAssert(!unplacedIcon || unplacedIcon.hidden,
                  @"A new mutual icon must not appear at its default frame before the title has room");
        text.view.frame = CGRectMake(0, 0, 80, 28);
        [header.view layoutSubviews];
        UIImageView *mutual = (UIImageView *)[header.view viewWithTag:9989];
        NSCAssert(mutual && !mutual.hidden && mutual.isAccessibilityElement && mutual.accessibilityLabel.length,
                  @"Mutual contacts receive an accessible icon");
        CGRect mutualFrame = [mutual convertRect:mutual.bounds toView:header.view];
        NSCAssert(CGRectGetMinX(mutualFrame) > CGRectGetMaxX([status convertRect:status.bounds toView:header.view]),
                  @"The mutual icon clears native status icons");
        header.peer = @5576711589;
        [header.view layoutSubviews];
        badge = (UILabel *)[header.view viewWithTag:9988];
        NSCAssert(!mutual.hidden && !badge.hidden && !CGRectIntersectsRect(badgeFrame(badge, header),
                  [mutual convertRect:mutual.bounds toView:header.view]), @"Owner and mutual badges coexist");
        CGRect stableFrame = mutual.frame;
        [header.view layoutSubviews];
        NSCAssert(CGRectEqualToRect(stableFrame, mutual.frame), @"Repeated layouts do not move accessories");
        header.peer = @43;
        status.hidden = YES;
        header.titleNode.view.center = CGPointMake(196.5, 140);
        UIFont *nameFont = [UIFont systemFontOfSize:28 weight:UIFontWeightMedium];
        text.attributedText = [[NSAttributedString alloc] initWithString:@"Мама" attributes:@{NSFontAttributeName: nameFont}];
        text.view.frame = CGRectMake(-40, 0, 80, nameFont.lineHeight);
        [header.view layoutSubviews];
        CGRect nameFrame = [text.view convertRect:text.view.bounds toView:header.view];
        CGRect alignedIcon = [mutual convertRect:mutual.bounds toView:header.view];
        NSCAssert(fabs(CGRectGetMidX(CGRectUnion(nameFrame, alignedIcon)) - CGRectGetMidX(header.view.bounds)) < 0.01,
                  @"Center the name and mutual icon as one group");
        CGFloat textBaseline = floor(nameFont.ascender * UIScreen.mainScreen.scale) / UIScreen.mainScreen.scale;
        CGFloat iconBaseline = CGRectGetMaxY(mutual.frame) - mutual.image.baselineOffsetFromBottom;
        NSCAssert(fabs(textBaseline - iconBaseline) < 0.01, @"Use the name font and symbol baseline instead of a fixed square");
        NSCAssert(mutual.image.size.width == mutual.bounds.size.width && mutual.image.size.height == mutual.bounds.size.height,
                  @"Preserve the symbol's natural proportions");
        CATransform3D centeredTransform = header.titleNode.view.layer.sublayerTransform;
        [header.view layoutSubviews];
        NSCAssert(CATransform3DEqualToTransform(centeredTransform, header.titleNode.view.layer.sublayerTransform),
                  @"Repeated layouts cannot accumulate title centering");
        header.titleNode.view.transform = CGAffineTransformMakeScale(0.75, 0.75);
        [header.view layoutSubviews];
        CGPoint scaledTextBaseline = [text.view convertPoint:CGPointMake(0, textBaseline) toView:header.view];
        CGPoint scaledIconBaseline = [mutual convertPoint:CGPointMake(0, mutual.bounds.size.height - mutual.image.baselineOffsetFromBottom) toView:header.view];
        NSCAssert(fabs(scaledTextBaseline.y - scaledIconBaseline.y) < 0.01, @"Keep baselines aligned during native header scaling");
        header.titleNode.view.transform = CGAffineTransformIdentity;
        header.titleNode.view.hidden = YES;
        [header.view layoutSubviews];
        NSCAssert(mutual.hidden, @"A hidden title also hides the mutual icon");
        header.titleNode.view.hidden = NO;
        header.mutual = NO;
        [header.view layoutSubviews];
        NSCAssert(![header.view viewWithTag:9989], @"Contact changes remove a stale mutual icon");
        NSCAssert(CATransform3DIsIdentity(header.titleNode.view.layer.sublayerTransform), @"Restore native name alignment when the icon disappears");
        puts("PASS profile badge: initial placement, title selection, native icons, resizing, controls, scroll, expansion and reuse");
    }
    return 0;
}
